"""The hosting files (brief 010 PR 5) must keep matching the app they deploy."""

from __future__ import annotations

import importlib
import tomllib
from pathlib import Path

from app.core.config import Settings
from app.main import create_app

REPO_DIR = Path(__file__).resolve().parents[3]
FLY = tomllib.loads((REPO_DIR / "fly.toml").read_text())
PROD_SECRETS = {
    "jwt_secret": "release-config-test-0123456789abcdef0123",
    "database_url": "postgresql+asyncpg://u:p@db.invalid/umma?ssl=require",
    "storage_access_key_id": "tid_test",
    "storage_secret_access_key": "tsec_test",
}


def _prod_settings() -> Settings:
    env = {key.lower(): value for key, value in FLY["env"].items()}
    return Settings(_env_file=None, **env, **PROD_SECRETS)


def test_fly_env_plus_required_secrets_is_a_valid_production_config() -> None:
    settings = _prod_settings()
    assert settings.environment == "prod"
    assert settings.auth_mode == "apple"


def test_fly_health_check_hits_a_real_route_and_dev_login_is_absent() -> None:
    app = create_app(_prod_settings())
    paths = set(app.openapi()["paths"])
    checks = FLY["http_service"]["checks"]
    assert checks and all(check["path"] in paths for check in checks)
    assert "/v1/auth/apple" in paths
    assert not any("dev-login" in path for path in paths)


def test_fly_processes_run_modules_that_exist() -> None:
    processes = FLY["processes"]
    assert set(processes) == {"web", "worker"}
    assert processes["web"].startswith("uvicorn app.main:app ")
    port = FLY["http_service"]["internal_port"]
    assert f"--port {port}" in processes["web"]
    assert FLY["http_service"]["processes"] == ["web"]
    module = processes["worker"].removeprefix("python -m ")
    assert hasattr(importlib.import_module(module), "main")
    assert FLY["deploy"]["release_command"] == "alembic upgrade head"


def test_dockerfile_and_ignore_file_are_where_fly_builds_from() -> None:
    dockerfile = REPO_DIR / FLY["build"]["dockerfile"]
    text = dockerfile.read_text()
    assert "ffmpeg" in text
    assert "\nUSER umma\n" in text
    ignore = (REPO_DIR / ".dockerignore").read_text().splitlines()
    assert "*" in ignore  # allow-list: everything is excluded by default
    assert "**/.env" in ignore
