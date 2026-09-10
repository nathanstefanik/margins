.PHONY: core mac-build mac-test mac-app mac-app-universal mac-run ios-core ios-archive ios-bump bump vendor-reader

core:
	./scripts/build-core.sh

ios-core:
	./scripts/build-xcframework.sh

# Release archive for TestFlight upload (sign with Apple Distribution via
# automatic signing; Xcode Organizer → Distribute App does the upload).
# -allowProvisioningUpdates lets Xcode register the App ID + iCloud
# container and (re)generate profiles during the archive.
ios-archive: ios-core
	xcodebuild -project apple/ios/Margins.xcodeproj -scheme Margins \
		-configuration Release \
		-destination 'generic/platform=iOS' \
		-archivePath build/Margins.xcarchive \
		-allowProvisioningUpdates \
		archive

# Bump the TestFlight build number (CURRENT_PROJECT_VERSION); run before
# every upload. Optional argument sets an explicit number.
ios-bump:
	./scripts/bump-build.sh

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

# Re-download the vendored reader JS (epub.js + jszip) at the pinned
# versions, verifying sha256 before copying into the resource bundle.
vendor-reader:
	./scripts/vendor-reader.sh

bump:
	./scripts/bump-version.sh $(VERSION)
