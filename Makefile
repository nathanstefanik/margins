.PHONY: core mac-build mac-test mac-app mac-run

core:
	./scripts/build-core.sh

mac-build: core
	swift build --package-path macos

mac-test: core
	swift run --package-path macos MarginsTests

mac-app: core
	./scripts/make-app.sh

mac-run: mac-app
	open build/Margins.app
