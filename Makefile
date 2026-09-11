.PHONY: test build app app-universal run ios-build ios-archive ios-bump mas-pkg bump vendor-reader

test:            ; swift test --package-path apple
build:           ; swift build --package-path apple
app:             ; ./scripts/make-app.sh
app-universal:   ; UNIVERSAL=1 ./scripts/make-app.sh
run: app         ; open build/Margins.app
ios-build:       ; xcodebuild -project apple/ios/Margins.xcodeproj -scheme Margins \
                     -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
ios-archive:     ; xcodebuild -project apple/ios/Margins.xcodeproj -scheme Margins \
                     -configuration Release -destination 'generic/platform=iOS' \
                     -archivePath build/Margins.xcarchive -allowProvisioningUpdates archive
ios-bump:        ; ./scripts/bump-build.sh
mas-pkg:         ; ./scripts/make-mas-pkg.sh
bump:            ; ./scripts/bump-version.sh $(VERSION)
vendor-reader:   ; ./scripts/vendor-reader.sh
