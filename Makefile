# Umma — one entry point for checks and dev loops. See CLAUDE.md.
SHELL := /bin/bash
SIM ?= iPhone 15
# $(SIM) on the newest runtime that has it (a bare `name=` resolves to OS:latest, which fails when
# that model only ships with an older runtime). Machines without $(SIM) fall back to a stock iPhone
# on the newest installed runtime; see ios/scripts/sim-pick.sh. CI passes SIM explicitly.
SIM_NAME := $(shell ios/scripts/sim-pick.sh name "$(SIM)")
SIM_OS ?= $(shell ios/scripts/sim-pick.sh os "$(SIM)")
# Locally, iOS targets lease this worktree's simulator from the shared pool
# (~/Documents/Projects/.claude/scripts/sim, see ~/.claude/CLAUDE.md), so parallel sessions never
# share or multiply simulators. CI, or `make ... SIM_POOL=`, uses $(SIM) via sim-pick.sh instead.
SIM_POOL ?= $(wildcard $(HOME)/Documents/Projects/.claude/scripts/sim)
ifneq ($(and $(SIM_POOL),$(if $(CI),,local)),)
SIM_UDID = $$($(SIM_POOL) acquire)
else
SIM_UDID = $$(xcrun simctl list devices available -j | python3 -c "import json,sys; d=json.load(sys.stdin); print([x['udid'] for k,v in d['devices'].items() if k.endswith('iOS-$(subst .,-,$(SIM_OS))') for x in v if x['name']=='$(SIM_NAME)'][0])")
endif

.PHONY: check backend-check ai-live-smoke voice-live-smoke ios-check ios-smoke release-ios env db-up db-down backend-dev backend-worker seed covers ios-project

check: backend-check ios-check

backend-check:
	$(MAKE) -C backend check

ai-live-smoke:
	$(MAKE) -C backend ai-live-smoke

voice-live-smoke:
	$(MAKE) -C backend voice-live-smoke

env:
	$(MAKE) -C backend env

db-up:
	$(MAKE) -C backend db-up

db-down:
	$(MAKE) -C backend db-down

backend-dev:
	$(MAKE) -C backend dev

backend-worker:
	$(MAKE) -C backend worker

seed:
	$(MAKE) -C backend seed

covers:
	$(MAKE) -C backend covers

ios-project:
	cd ios && xcodegen generate

# Ad-hoc signing (identity "-") needs no certificate or profile, but unlike CODE_SIGNING_ALLOWED=NO
# it embeds the keychain-access-groups entitlement, which the simulator Keychain requires (-34018).
# -parallel-testing-enabled NO: parallel testing boots a simulator clone per worker.
ios-check: ios-project
	cd ios && UDID=$(SIM_UDID) && rm -rf build/ios-check.xcresult && { xcodebuild test -project Umma.xcodeproj -scheme Umma \
		-destination "platform=iOS Simulator,id=$$UDID" -parallel-testing-enabled NO \
		CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO -quiet \
		-resultBundlePath build/ios-check.xcresult \
		|| { python3 scripts/print-test-failures.py build/ios-check.xcresult; exit 1; }; }

# Live smoke: fresh install → two-step dev sign-in (code read from the backend log) → seeded
# recipe. Needs `make backend-dev` running with its log at SMOKE_LOG (default below).
SMOKE_LOG ?= $(CURDIR)/backend/dev.log
ios-smoke: ios-project
	cd ios && UDID=$(SIM_UDID) && xcrun simctl boot "$$UDID" 2>/dev/null; xcrun simctl uninstall "$$UDID" com.umma.ios 2>/dev/null; \
	xcodebuild test -project Umma.xcodeproj -scheme UmmaSmoke \
		-destination "platform=iOS Simulator,id=$$UDID" -parallel-testing-enabled NO \
		CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO \
		UMMA_SMOKE_LOG="$(SMOKE_LOG)" -quiet

# TestFlight (brief 010, docs/release/testflight.md). Wraps the shared personal pipeline
# (~/Documents/Projects/IOS-RELEASE.md); credentials stay in ~/.appstoreconnect, never here.
#   make release-ios                          archive only, prints bundle id / version / build
#   make release-ios UPLOAD=1                 archive and upload to App Store Connect
#   make release-ios UPLOAD=1 VERSION=0.2.0 BUILD=7
# BUILD defaults to a UTC timestamp, so every upload gets a new, higher build number. The version
# and build reach xcodebuild through XCODE_XCCONFIG_FILE, which overrides project.yml's defaults.
RELEASE_SCRIPT ?= $(HOME)/Documents/Projects/.claude/scripts/testflight-upload.sh
RELEASE_XCCONFIG := $(CURDIR)/ios/build/release-version.xcconfig
VERSION ?=
BUILD ?= $(shell date -u +%Y%m%d%H%M)
UPLOAD ?=
release-ios: ios-project
	@test -x "$(RELEASE_SCRIPT)" || { echo "missing $(RELEASE_SCRIPT) (see docs/release/testflight.md)" >&2; exit 1; }
	@mkdir -p ios/build
	@{ echo "CURRENT_PROJECT_VERSION = $(BUILD)"; $(if $(VERSION),echo "MARKETING_VERSION = $(VERSION)";) } > "$(RELEASE_XCCONFIG)"
	XCODE_XCCONFIG_FILE="$(RELEASE_XCCONFIG)" "$(RELEASE_SCRIPT)" ios/Umma.xcodeproj Umma $(if $(UPLOAD),,--archive-only)
