.PHONY: core mac-build mac-test mac-app mac-app-universal mac-run bump

core:
	./scripts/build-core.sh

mac-build: core
	swift build --package-path macos

mac-test: core
	swift run --package-path macos MarginsTests

mac-app: core
	./scripts/make-app.sh

mac-app-universal:
	UNIVERSAL=1 ./scripts/build-core.sh
	UNIVERSAL=1 ./scripts/make-app.sh

mac-run: mac-app
	open build/Margins.app

bump:
	./scripts/bump-version.sh $(VERSION)
