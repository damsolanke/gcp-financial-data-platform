.PHONY: build test lint bench up down generate dbt tf-plan tf-validate ci clean

# ──────────────────────────────────────────────────────────────
# Build
# ──────────────────────────────────────────────────────────────

build: build-ingestion build-governance

build-ingestion:
	cd ingestion-service && go build -o bin/server ./cmd/server

build-governance:
	cd governance && pip install -r requirements.txt -q

# ──────────────────────────────────────────────────────────────
# Test
# ──────────────────────────────────────────────────────────────

test: test-go test-python test-dbt test-dags

test-go:
	cd ingestion-service && go test -race -coverprofile=coverage.out ./...

test-python:
	cd governance && python -m pytest tests/ -v --cov=app --cov-report=term-missing

test-dags:
	cd orchestration && python -m pytest tests/ -v

test-dbt:
	cd dbt_project && dbt parse && dbt compile

test-integration:
	cd ingestion-service && go test -race -tags=integration ./...

# ──────────────────────────────────────────────────────────────
# Lint
# ──────────────────────────────────────────────────────────────

lint: lint-go lint-python lint-terraform

lint-go:
	cd ingestion-service && go vet ./... && golangci-lint run

lint-python:
	cd governance && ruff check . && mypy app/

lint-terraform:
	terraform -chdir=terraform/environments/dev fmt -check -recursive
	terraform -chdir=terraform/environments/dev validate

# ──────────────────────────────────────────────────────────────
# Benchmark
# ──────────────────────────────────────────────────────────────

bench:
	cd ingestion-service && go test -bench=. -benchmem ./internal/validator/

# ──────────────────────────────────────────────────────────────
# Local Development
# ──────────────────────────────────────────────────────────────

up:
	docker compose up -d

down:
	docker compose down

logs:
	docker compose logs -f

# ──────────────────────────────────────────────────────────────
# Data
# ──────────────────────────────────────────────────────────────

generate:
	python scripts/generate_sample_data.py --seed 42 --output-dir ./data

# ──────────────────────────────────────────────────────────────
# dbt
# ──────────────────────────────────────────────────────────────

dbt:
	cd dbt_project && dbt run && dbt test

dbt-docs:
	cd dbt_project && dbt docs generate && dbt docs serve

# ──────────────────────────────────────────────────────────────
# Terraform
# ──────────────────────────────────────────────────────────────

tf-plan:
	terraform -chdir=terraform/environments/dev plan

tf-validate:
	@for dir in terraform/modules/*/; do \
		echo "Validating $$dir..."; \
		terraform -chdir=$$dir init -backend=false -input=false > /dev/null 2>&1; \
		terraform -chdir=$$dir validate; \
	done

tf-fmt:
	terraform fmt -recursive terraform/

# ──────────────────────────────────────────────────────────────
# CI (run everything CI runs, locally)
# ──────────────────────────────────────────────────────────────

ci: lint test

# ──────────────────────────────────────────────────────────────
# Clean
# ──────────────────────────────────────────────────────────────

clean:
	rm -rf ingestion-service/bin/ ingestion-service/coverage.out
	rm -rf governance/.mypy_cache governance/.pytest_cache governance/htmlcov
	rm -rf dbt_project/target dbt_project/logs dbt_project/dbt_packages
	rm -rf data/
