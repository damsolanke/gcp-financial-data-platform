"""Application configuration via environment variables (12-factor)."""

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """All config comes from environment. No config files in production."""

    model_config = SettingsConfigDict(env_prefix="", case_sensitive=False)

    port: int = 8081
    log_level: str = "info"
    environment: str = "development"

    # Auth
    secret_key: str = "change-me-in-production"
    access_token_expire_minutes: int = 30
    algorithm: str = "HS256"

    # GCP
    bigquery_project_id: str = "local-project"
    bigquery_dataset_audit: str = "audit"


settings = Settings()
