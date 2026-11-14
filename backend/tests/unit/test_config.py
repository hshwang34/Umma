"""Settings refuse insecure configurations at startup (fail closed)."""

from __future__ import annotations

import pytest
from pydantic import ValidationError

from app.core.config import MIN_JWT_SECRET_BYTES, REPO_DIR, Settings

GOOD_SECRET = "x" * MIN_JWT_SECRET_BYTES


@pytest.fixture(autouse=True)
def _no_ambient_env(monkeypatch: pytest.MonkeyPatch) -> None:
    for key in (
        "JWT_SECRET",
        "AUTH_MODE",
        "ENVIRONMENT",
        "DEV_LOGIN_ECHO_CODE",
        "CLIENT_IP_HEADER",
        "AI_USER_DAILY_CAP_USD",
        "AI_USER_DAILY_LIVE_CAP_USD",
        "AI_MONTH_SOFT_CAP_USD",
        "AI_MONTH_HARD_CAP_USD",
    ):
        monkeypatch.delenv(key, raising=False)


def test_jwt_secret_is_required() -> None:
    with pytest.raises(ValidationError, match="jwt_secret"):
        Settings(_env_file=None, auth_mode="dev")


def test_auth_mode_is_required() -> None:
    with pytest.raises(ValidationError, match="auth_mode"):
        Settings(_env_file=None, jwt_secret=GOOD_SECRET)


@pytest.mark.parametrize("secret", ["", "short", "ci-only", "x" * (MIN_JWT_SECRET_BYTES - 1)])
def test_short_jwt_secret_is_refused(secret: str) -> None:
    with pytest.raises(ValidationError, match="at least 32 bytes"):
        Settings(_env_file=None, jwt_secret=secret, auth_mode="dev")


def test_secret_length_is_measured_in_bytes_not_characters() -> None:
    # 16 two-byte characters = 32 bytes: accepted; 15 = 30 bytes: refused.
    assert Settings(_env_file=None, jwt_secret="\u00e9" * 16, auth_mode="dev").jwt_secret
    with pytest.raises(ValidationError):
        Settings(_env_file=None, jwt_secret="\u00e9" * 15, auth_mode="dev")


def test_dev_auth_in_prod_is_refused() -> None:
    with pytest.raises(ValidationError, match="AUTH_MODE=dev is only allowed"):
        Settings(_env_file=None, jwt_secret=GOOD_SECRET, environment="prod", auth_mode="dev")


@pytest.mark.parametrize("environment", ["dev", "test"])
def test_dev_auth_allowed_in_dev_and_test(environment: str) -> None:
    settings = Settings(
        _env_file=None, jwt_secret=GOOD_SECRET, environment=environment, auth_mode="dev"
    )
    assert settings.auth_mode == "dev"


PROD_STORAGE = {
    "storage_endpoint_url": "https://t3.storage.dev",
    "storage_access_key_id": "tid_real_key",
    "storage_secret_access_key": "tsec_real_secret",
    # Brief 010: prod states its AI caps and the proxy's client-IP header explicitly.
    "ai_user_daily_cap_usd": 0.5,
    "ai_user_daily_live_cap_usd": 1.15,
    "ai_month_soft_cap_usd": 15,
    "ai_month_hard_cap_usd": 22,
    "client_ip_header": "Fly-Client-IP",
}


def test_prod_with_apple_auth_is_allowed() -> None:
    settings = Settings(
        _env_file=None,
        jwt_secret=GOOD_SECRET,
        environment="prod",
        auth_mode="apple",
        **PROD_STORAGE,
    )
    assert settings.environment == "prod"


@pytest.mark.parametrize(
    "override, match",
    [
        ({"storage_access_key_id": "umma-dev"}, "STORAGE_ACCESS_KEY_ID"),
        ({"storage_secret_access_key": "umma-dev-secret"}, "STORAGE_ACCESS_KEY_ID"),
        ({"storage_endpoint_url": "http://localhost:9000"}, "https://"),
        ({"storage_endpoint_url": None}, "https://"),
    ],
)
def test_prod_refuses_dev_storage(override: dict[str, object], match: str) -> None:
    with pytest.raises(ValidationError, match=match):
        Settings(
            _env_file=None,
            jwt_secret=GOOD_SECRET,
            environment="prod",
            auth_mode="apple",
            **{**PROD_STORAGE, **override},
        )


def _prod(**override: object) -> Settings:
    values = {**PROD_STORAGE, **override}
    values = {key: value for key, value in values.items() if value is not ...}
    return Settings(
        _env_file=None, jwt_secret=GOOD_SECRET, environment="prod", auth_mode="apple", **values
    )


@pytest.mark.parametrize(
    "cap",
    [
        "ai_user_daily_cap_usd",
        "ai_user_daily_live_cap_usd",
        "ai_month_soft_cap_usd",
        "ai_month_hard_cap_usd",
    ],
)
def test_prod_refuses_an_unset_or_zero_ai_cap(cap: str) -> None:
    with pytest.raises(ValidationError, match=f"{cap.upper()} must be set above 0"):
        _prod(**{cap: ...})  # left to its default: prod has to state it
    # A zero hard cap is caught first by the older "soft must not exceed hard" rule.
    with pytest.raises(ValidationError, match=r"must be set above 0|must not exceed"):
        _prod(**{cap: 0})


@pytest.mark.parametrize(
    "limit",
    [
        "rate_limit_sign_in_per_ip_per_minute",
        "rate_limit_per_ip_per_minute",
        "rate_limit_per_user_per_minute",
        "rate_limit_costly_per_user_per_minute",
    ],
)
def test_prod_refuses_a_rate_limit_switched_off(limit: str) -> None:
    with pytest.raises(ValidationError, match=f"{limit.upper()} must be above 0"):
        _prod(**{limit: 0})


@pytest.mark.parametrize("header", [..., None, ""])
def test_prod_refuses_a_missing_client_ip_header(header: object) -> None:
    with pytest.raises(ValidationError, match="CLIENT_IP_HEADER must be set in prod"):
        _prod(client_ip_header=header)


def test_dev_needs_no_caps_header_or_limits() -> None:
    settings = Settings(
        _env_file=None,
        jwt_secret=GOOD_SECRET,
        auth_mode="dev",
        ai_user_daily_cap_usd=0,
        rate_limit_per_ip_per_minute=0,
    )
    assert settings.client_ip_header is None


@pytest.mark.parametrize("environment", ["dev", "prod"])
def test_echo_code_refused_outside_test_environment(environment: str) -> None:
    with pytest.raises(ValidationError, match="DEV_LOGIN_ECHO_CODE"):
        Settings(
            _env_file=None,
            jwt_secret=GOOD_SECRET,
            environment=environment,
            auth_mode="apple",
            dev_login_echo_code=True,
        )


def test_echo_code_allowed_in_test_environment() -> None:
    settings = Settings(
        _env_file=None,
        jwt_secret=GOOD_SECRET,
        environment="test",
        auth_mode="dev",
        dev_login_echo_code=True,
    )
    assert settings.dev_login_echo_code is True


def test_echo_code_defaults_off() -> None:
    assert not Settings(_env_file=None, jwt_secret=GOOD_SECRET, auth_mode="dev").dev_login_echo_code


def test_env_example_sets_auth_mode_and_a_long_enough_secret() -> None:
    values = dict(
        line.split("#", 1)[0].strip().split("=", 1)
        for line in (REPO_DIR / ".env.example").read_text().splitlines()
        if "=" in line and not line.startswith("#")
    )
    assert values["AUTH_MODE"] == "dev"
    # The committed placeholder is long enough but is refused *as a placeholder*, so copying
    # .env.example verbatim never yields a working (and therefore shared) secret.
    with pytest.raises(ValidationError, match="placeholder"):
        Settings(_env_file=None, jwt_secret=values["JWT_SECRET"], auth_mode="dev")


def test_ci_workflow_sets_auth_mode_and_secret() -> None:
    workflow = (REPO_DIR / ".github" / "workflows" / "backend.yml").read_text()
    assert "AUTH_MODE: dev" in workflow
    secret = next(
        line.split(":", 1)[1].strip() for line in workflow.splitlines() if "JWT_SECRET:" in line
    )
    assert Settings(_env_file=None, jwt_secret=secret, auth_mode="dev")


def test_placeholder_secret_is_refused() -> None:
    with pytest.raises(ValidationError):
        Settings(jwt_secret="change-me-dev-only-32-bytes-minimum-please", auth_mode="dev")


def test_google_keys_url_must_be_https() -> None:
    with pytest.raises(ValidationError, match="GOOGLE_KEYS_URL"):
        Settings(
            _env_file=None,
            jwt_secret=GOOD_SECRET,
            auth_mode="apple",
            google_keys_url="http://www.googleapis.com/oauth2/v3/certs",
        )
