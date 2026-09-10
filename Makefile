COMPOSE := docker compose -f infra/docker-compose.yml
REGION ?= europe/great-britain/england/greater-london

.PHONY: up down logs migrate api worker test lint format ios-generate osm routing

up:            ## start db + redis
	$(COMPOSE) up -d db redis

down:
	$(COMPOSE) down

logs:
	$(COMPOSE) logs -f

migrate:
	cd backend && alembic upgrade head

api:
	cd backend && uvicorn app.main:app --reload

worker:
	cd backend && python -m app.jobs.worker

test:
	cd backend && pytest -m "not integration" -q

lint:
	cd backend && ruff check . && ruff format --check .

format:
	cd backend && ruff format . && ruff check . --fix

ios-generate:
	cd ios && xcodegen generate

osm:
	infra/scripts/download-osm.sh $(REGION)

routing:
	$(COMPOSE) --profile routing up graphhopper
