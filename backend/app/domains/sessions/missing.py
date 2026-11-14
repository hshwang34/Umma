"""The ``missing_ingredient`` coach intent (brief 017 PR 7): "I don't have that" while cooking.

The reply is an OFFER and nothing else. This module only reads: it never touches the pantry,
the session or the shopping list. Each part of the offer names the existing, confirmed path the
phone uses if the cook says yes:

* swap → the ``approve_adaptation`` command with ``swap.adaptation`` as its body (the one swap
  policy runs again there, with the cook's allergies as they are then);
* shopping list → ``POST /shopping-list`` with ``shopping_name``;
* pantry → ``DELETE /pantry/{pantry_item_id}``.

It is deterministic: the intent comes from the cook's own words (``intent.missing_object``),
the swap from the vetted seed rules filtered by the swap policy (allergy first), so it answers
the same with ``AI_PROVIDER=mock`` and never calls a model. Recipe text can't trigger it.
"""

from __future__ import annotations

import re
import uuid
from typing import Any, Literal

from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.models import PantryItem, SessionAdaptation, User
from app.domains.matching.dictionary import IngredientDictionary, load_dictionary
from app.domains.matching.normalize import alternatives, normalize
from app.domains.recipes.schemas import IngredientOut
from app.domains.safety.content import candidate_safety_risks, scan
from app.domains.sessions import intent
from app.domains.shopping import service as shopping
from app.domains.substitutions import policy
from app.domains.substitutions.rules import load_rules
from app.domains.substitutions.service import VersionContext, allergy_warning_for, target_names
from app.domains.users import preferences

_CONF_ORDER = {"high": 0, "medium": 1, "low": 2}
NOTHING_CHANGES = "Nothing changes until you confirm."


class MissingCandidate(BaseModel):
    ingredient_ref: str
    name: str


class SwapAdaptation(BaseModel):
    """Exactly the ``adaptation`` body of the ``approve_adaptation`` command."""

    ingredient_ref: str
    replacement: str
    ratio_or_amount: str | None
    source: Literal["rule"] = "rule"


class MissingSwap(BaseModel):
    candidate: str
    ratio_or_amount: str
    kind: Literal["close_equivalent", "flavor_adaptation", "structural_substitution"]
    in_pantry: bool
    risks: list[str]
    allergy_warning: str | None
    adaptation: SwapAdaptation


class MissingIngredientOut(BaseModel):
    """``which``: the coach is asking which ingredient (``candidates``). ``offer``: one
    ingredient is named and the rest of the fields describe what the cook may confirm."""

    status: Literal["offer", "which"]
    ingredient_ref: str | None = None
    name: str | None = None
    optional: bool = False
    candidates: list[MissingCandidate] = Field(default_factory=list)
    swap: MissingSwap | None = None
    no_swap_reason: str | None = None
    shopping_name: str | None = None
    on_shopping_list: bool = False
    pantry_item_id: uuid.UUID | None = None
    requires_confirmation: Literal[True] = True


def _named(obj: str, ingredient: IngredientOut, dictionary: IngredientDictionary) -> bool:
    names = [ingredient.name, *alternatives(ingredient.name)]
    if any(re.search(rf"\b{re.escape(n.lower())}(?:e?s)?\b", obj) for n in names):
        return True
    key = normalize(obj, dictionary).key
    return bool(key) and key in target_names(ingredient.name, dictionary)


def resolve(
    obj: str, ctx: VersionContext, step_index: int, dictionary: IngredientDictionary
) -> list[IngredientOut] | None:
    """The ingredients the cook may mean. One → the offer; several (or none) → ask which.
    ``None``: they named something that is not in this recipe, so it is not this intent."""
    if obj:
        named = [i for i in ctx.ingredients if _named(obj, i, dictionary)]
        return named or None
    refs = ctx.steps[step_index].ingredient_refs if ctx.steps else []
    in_step = [i for i in ctx.ingredients if i.id in refs]
    return in_step or list(ctx.ingredients)


async def propose(
    session: AsyncSession,
    user: User,
    ctx: VersionContext,
    step_index: int,
    adaptations: list[SessionAdaptation],
    query: str,
) -> tuple[str, MissingIngredientOut] | None:
    """(answer text, offer) for an "I don't have …" query, else ``None``. Read only."""
    obj = intent.missing_object(query)
    if obj is None or not ctx.ingredients:
        return None
    dictionary = await load_dictionary(session)
    found = resolve(obj, ctx, step_index, dictionary)
    if found is None:
        return None
    if len(found) != 1:
        names = [i.name for i in found]
        listed = ", ".join(names[:-1]) + f" or {names[-1]}"
        where = "This step uses" if not obj and len(found) < len(ctx.ingredients) else "I see"
        return (
            f"{where} {listed}. My suggestion: tell me which one you don't have.",
            MissingIngredientOut(
                status="which",
                candidates=[MissingCandidate(ingredient_ref=i.id, name=i.name) for i in found],
            ),
        )
    ingredient = found[0]
    names = target_names(ingredient.name, dictionary)
    options = alternatives(ingredient.name)
    shopping_name = options[0] if len(options) > 1 else ingredient.name
    pantry = list(
        (
            await session.execute(
                select(PantryItem)
                .where(PantryItem.owner_user_id == user.id)
                .order_by(PantryItem.last_confirmed_at.desc().nulls_last(), PantryItem.id)
            )
        ).scalars()
    )
    held = next((p for p in pantry if p.normalized_name in names), None)
    offer = MissingIngredientOut(
        status="offer",
        ingredient_ref=ingredient.id,
        name=ingredient.name,
        optional=ingredient.optional,
        shopping_name=shopping_name,
        on_shopping_list=await shopping.is_listed(session, user, shopping_name, dictionary),
        pantry_item_id=held.id if held else None,
    )

    approved = next((a for a in adaptations if a.ingredient_ref == ingredient.id), None)
    if approved is not None:
        offer.no_swap_reason = f"You already approved {approved.replacement} instead."
    else:
        offer.swap, offer.no_swap_reason = await _swap(
            session, user, ctx, ingredient, names, {p.normalized_name for p in pantry}, dictionary
        )
    return _answer(ingredient, offer), offer


async def _swap(
    session: AsyncSession,
    user: User,
    ctx: VersionContext,
    ingredient: IngredientOut,
    names: list[str],
    in_pantry: set[str],
    dictionary: IngredientDictionary,
) -> tuple[MissingSwap | None, str | None]:
    """The best vetted swap the policy allows, pantry first (SUB-03), or why there is none
    (SUB-05). The same policy as ``/substitutions/suggest``; rules only, no advisor call."""
    target = policy.swap_target(
        ingredient,
        names,
        ctx.steps,
        await load_rules(session),
        ctx.title,
        ctx.dietary_warnings + ctx.creator_notes,
    )
    blocked = policy.target_blocker(target)
    if blocked is not None:
        return None, blocked.reason
    prof = await preferences.profile(session, user)
    allowed: list[tuple[Any, bool]] = [
        (s, bool(scan(s.candidate, dictionary).canonical_names & in_pantry))
        for s in (target.rule.suggestions if target.rule else [])
        if policy.candidate_blocker(
            target,
            s.candidate,
            s.ratio_or_amount,
            prof,
            dictionary,
            include_avoid=True,
            source="rule",
        )
        is None
    ]
    if not allowed:
        return None, f"I don't know a swap for {ingredient.name} that fits you."
    best, have = min(allowed, key=lambda pair: (not pair[1], _CONF_ORDER[pair[0].confidence]))
    return (
        MissingSwap(
            candidate=best.candidate,
            ratio_or_amount=best.ratio_or_amount,
            kind=best.kind,
            in_pantry=have,
            risks=list(dict.fromkeys([*best.risks, *candidate_safety_risks(best.candidate)])),
            allergy_warning=allergy_warning_for(best.candidate, bool(prof.allergies), dictionary),
            adaptation=SwapAdaptation(
                ingredient_ref=ingredient.id,
                replacement=best.candidate,
                ratio_or_amount=best.ratio_or_amount,
            ),
        ),
        None,
    )


def _answer(ingredient: IngredientOut, offer: MissingIngredientOut) -> str:
    name = ingredient.name
    amount = "" if ingredient.quantity is None else f"{ingredient.quantity:g} "
    if ingredient.quantity is not None and ingredient.unit:
        amount += f"{ingredient.unit} "
    parts: list[str] = []
    swap = offer.swap
    if swap is not None:
        where = "and it's in your pantry" if swap.in_pantry else "but it isn't in your pantry"
        parts.append(f"A common swap is {swap.candidate} ({swap.ratio_or_amount}), {where}.")
        parts.append("I can swap it in for this cook.")
    elif offer.no_swap_reason:
        parts.append(offer.no_swap_reason.rstrip(".") + ".")
    if ingredient.optional:
        parts.append("It's optional, so you can also leave it out.")
    if offer.on_shopping_list:
        parts.append(f"{offer.shopping_name} is already on your shopping list.")
    else:
        parts.append(f"I can add {offer.shopping_name} to your shopping list.")
    if offer.pantry_item_id is not None:
        parts.append("Your pantry still lists it; I can take it off.")
    parts.append(NOTHING_CHANGES)
    return f"The recipe says: {amount}{name}. My suggestion: {' '.join(parts)}"
