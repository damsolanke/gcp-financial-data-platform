"""Application configuration via environment variables (12-factor)."""

from pydantic import model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """All config comes from environment. No config files in production."""

    model_config = SettingsConfigDict(env_prefix="", case_sensitive=False)

    port: int = 8081
    log_level: str = "info"
    # dev | staging | prod -- the same value Terraform, dbt and the DAG use.
    environment: str = "dev"

    # Auth
    secret_key: str = "change-me-in-production"
    access_token_expire_minutes: int = 30
    algorithm: str = "HS256"

    # GCP. Datasets follow fdp_<env>_<layer> (terraform/modules/bigquery);
    # BIGQUERY_DATASET_AUDIT overrides the derived fdp_<environment>_audit.
    bigquery_project_id: str = "local-project"
    bigquery_dataset_audit: str = ""

    @model_validator(mode="after")
    def _derive_audit_dataset(self) -> "Settings":
        if not self.bigquery_dataset_audit:
            self.bigquery_dataset_audit = f"fdp_{self.environment}_audit"
        return self


settings = Settings()
