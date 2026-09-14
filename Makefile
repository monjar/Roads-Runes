COMPOSE := docker compose -f infra/docker-compose.yml
DEVICE ?= 79CE2CE2-3471-5CBC-8DBD-B0E4673AD5F3   # xcrun devicectl list devices
REGION ?= europe/united-kingdom/england/greater-london

# TestFlight refuses a build number it has seen before, so the default is the
# minute you ran this. Two dot-separated parts: each one has to fit in an int32.
BUILD ?= $(shell date -u +%Y%m%d.%H%M)
# App Store Connect API key: the id and issuer of a key whose AuthKey_<id>.p8 sits
# in ~/private_keys. The same three the `testflight` workflow takes as secrets.
ASC_KEY_ID ?=
ASC_ISSUER_ID ?=

.PHONY: up down logs migrate api worker seed test lint format ios-generate osm routing ios-ui-test ios-testflight

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

ios-testflight: ## archive, sign and upload a build to TestFlight (needs ASC_KEY_ID and ASC_ISSUER_ID)
	@test -n "$(ASC_KEY_ID)" -a -n "$(ASC_ISSUER_ID)" || { echo "set ASC_KEY_ID and ASC_ISSUER_ID (see .github/workflows/testflight.yml)"; exit 1; }
	cd ios && xcodegen generate
	cd ios && xcodebuild archive -project RoadsAndRunes.xcodeproj -scheme RoadsAndRunes -configuration Release -destination 'generic/platform=iOS' -archivePath build/RoadsAndRunes.xcarchive -allowProvisioningUpdates -authenticationKeyPath $$HOME/private_keys/AuthKey_$(ASC_KEY_ID).p8 -authenticationKeyID $(ASC_KEY_ID) -authenticationKeyIssuerID $(ASC_ISSUER_ID) CURRENT_PROJECT_VERSION=$(BUILD)
	cd ios && xcodebuild -exportArchive -archivePath build/RoadsAndRunes.xcarchive -exportOptionsPlist ExportOptions.plist -exportPath build/export -allowProvisioningUpdates -authenticationKeyPath $$HOME/private_keys/AuthKey_$(ASC_KEY_ID).p8 -authenticationKeyID $(ASC_KEY_ID) -authenticationKeyIssuerID $(ASC_ISSUER_ID)
	xcrun altool --upload-app -f ios/build/export/RoadsAndRunes.ipa -t ios --apiKey $(ASC_KEY_ID) --apiIssuer $(ASC_ISSUER_ID)

osm:
	infra/scripts/download-osm.sh $(REGION)

routing:
	$(COMPOSE) --profile routing up graphhopper
