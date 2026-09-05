.PHONY: core mac-build mac-test mac-app mac-app-universal mac-run ios-core bump

core:
	./scripts/build-core.sh

ios-core:
	./scripts/build-xcframework.sh

mac-build: core
	swift build --package-path apple

mac-test: core
	swift run --package-path apple MarginsTests

mac-app: core
	./scripts/make-app.sh

mac-app-universal:
	UNIVERSAL=1 ./scripts/build-core.sh
	UNIVERSAL=1 ./scripts/make-app.sh

mac-run: mac-app
	open build/Margins.app

bump:
	./scripts/bump-version.sh $(VERSION)
