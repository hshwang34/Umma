"""Grocery receipt photo → pantry (brief 017 PR 2). Owner only; the photo is never stored."""

from __future__ import annotations

import asyncio
import logging
from datetime import UTC, datetime

import pydantic
from fastapi import APIRouter, Request

from app.ai.guard import provider_for
from app.ai.providers.base import ReceiptDraft, ReceiptRequest
from app.core.errors import (
    AppError,
    ProviderOutputInvalid,
    ProviderUnavailable,
    UnsupportedMediaType,
    ValidationError,
)
from app.core.security import CurrentUser
from app.db.engine import DbSession
from app.domains.matching.dictionary import load_dictionary
from app.domains.pantry import receipts, upload
from app.domains.pantry.observations import PROVIDER_TIMEOUT_SECONDS
from app.domains.pantry.schemas import ReceiptResult

log = logging.getLogger("umma.pantry.receipts")
router = APIRouter(prefix="/pantry/receipts", tags=["pantry"])

_RECEIPT_BODY = {
    "requestBody": {
        "required": True,
        "content": {
            "multipart/form-data": {
                "schema": {
                    "type": "object",
                    "required": ["image"],
                    "properties": {"image": {"type": "string", "format": "binary"}},
                }
            }
        },
    }
}


async def _receipt_request(request: Request) -> ReceiptRequest:
    """Same limits as the pantry photo: capped body, one JPEG/PNG/HEIC, kept in memory only."""
    content_type = request.headers.get("content-type", "")
    if content_type.split(";", 1)[0].strip().lower() != "multipart/form-data":
        raise UnsupportedMediaType("Send the receipt photo as multipart/form-data")
    body = await upload.read_body_capped(request)
    parts = upload.parse_multipart(body, content_type)
    del body
    image = parts.get("image")
    if image is None or image.filename is None or not image.data:
        raise ValidationError("A receipt needs an image file", extra={"fields": ["image"]})
    data = bytes(image.data)
    image.data.clear()
    return ReceiptRequest(image_bytes=data, image_mime_type=upload.sniff_image(data))


@router.post("", response_model=ReceiptResult, openapi_extra=_RECEIPT_BODY)
async def read_receipt(request: Request, session: DbSession, user: CurrentUser) -> ReceiptResult:
    # No hourly limit of its own: the observation limit counts observation rows, which a receipt
    # does not write. Every real read is bounded by the cost guard's daily cap (DECISIONS #19).
    receipt_request = await _receipt_request(request)
    provider = provider_for(request, user.id)
    dictionary = await load_dictionary(session)
    await session.commit()  # the provider call holds no transaction, lock or pooled connection
    try:
        raw = await asyncio.wait_for(
            provider.read_receipt(receipt_request), timeout=PROVIDER_TIMEOUT_SECONDS
        )
        draft = ReceiptDraft.model_validate(raw.model_dump(warnings=False))
    except AppError:  # AIResting (over budget), malformed output: nothing was saved
        raise
    except pydantic.ValidationError as exc:
        raise ProviderOutputInvalid("The receipt came back malformed; try again") from exc
    except Exception as exc:
        log.warning("receipt provider failed", extra={"error_type": type(exc).__name__})
        raise ProviderUnavailable("The receipt reader is unavailable; try again") from exc
    finally:
        del receipt_request  # the photo is processed in memory only (PRIV-01)
    return await receipts.save_receipt(session, user, draft, dictionary, datetime.now(UTC))
