COMPOSE := docker compose -f infra/docker-compose.yml
DEVICE ?= 79CE2CE2-3471-5CBC-8DBD-B0E4673AD5F3   # xcrun devicectl list devices
REGION ?= europe/united-kingdom/england/greater-london

.PHONY: up down logs migrate api worker seed test lint format ios-generate osm routing ios-ui-test

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

seed:          ## dev rider, curated discoveries and quests around Rotherhithe
	cd backend && python scripts/seed_dev.py

test:
	cd backend && pytest -m "not integration" -q

lint:
	cd backend && ruff check . && ruff format --check .

format:
	cd backend && ruff format . && ruff check . --fix

ios-generate:
	cd ios && xcodegen generate

ios-ui-test:   ## main-flow UI tests on the iPhone simulator; needs `make api`
	cd ios && xcodegen generate && xcodebuild test -project RoadsAndRunes.xcodeproj -scheme RoadsAndRunesUITests -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max'

ios-device:    ## build, install and launch on a connected iPhone (paid team, hosted backend)
	cd ios && xcodegen generate && xcodebuild -project RoadsAndRunes.xcodeproj -scheme RoadsAndRunes -configuration Debug -destination 'generic/platform=iOS' -allowProvisioningUpdates API_BASE_URL=https://roadsandrunes.fly.dev build
	xcrun devicectl device install app --device $(DEVICE) $$(ls -d ~/Library/Developer/Xcode/DerivedData/RoadsAndRunes-*/Build/Products/Debug-iphoneos/RoadsAndRunes.app | head -1)
	xcrun devicectl device process launch --device $(DEVICE) com.roadsandrunes.app

osm:
	infra/scripts/download-osm.sh $(REGION)

routing:
	$(COMPOSE) --profile routing up graphhopper
