# Admiral — build & local validation
.PHONY: all validate test generate build sign snapshot run clean

APP := App/build/Build/Products/Debug/Admiral.app

all: validate

## Run every local gate (tests, build, UI snapshot) with artifacts in .validation/
validate:
	./scripts/validate.sh

## AdmiralCore unit tests
test:
	swift test

## Regenerate the Xcode project from project.yml
generate:
	cd App && xcodegen generate

## Build the app (unsigned), then sign with the stable local identity
build: generate
	xcodebuild -project App/Admiral.xcodeproj -scheme Admiral -configuration Debug \
		-derivedDataPath App/build -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO
	./scripts/sign-app.sh $(APP)

## Render the UI to .validation/ui.png (no display / permission needed)
snapshot: build
	mkdir -p .validation
	ADMIRAL_SNAPSHOT="$(PWD)/.validation/ui.png" $(APP)/Contents/MacOS/Admiral

## Launch the real app with demo data
run: build
	ADMIRAL_DEMO=1 open $(APP)

clean:
	rm -rf App/build .build .validation App/Admiral.xcodeproj
