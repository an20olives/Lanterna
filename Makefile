BUILD := build

.PHONY: gen ipa-tvos ipa-ios app-macos install-macos clean

gen:
	xcodegen generate

ipa-tvos: gen
	xcodebuild -project Lanterna.xcodeproj -scheme Lanterna-tvOS -configuration Release -sdk appletvos \
	  -derivedDataPath $(BUILD)/dd CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build
	rm -rf $(BUILD)/ipa-tvos && mkdir -p $(BUILD)/ipa-tvos/Payload
	cp -R $(BUILD)/dd/Build/Products/Release-appletvos/Lanterna.app $(BUILD)/ipa-tvos/Payload/
	cd $(BUILD)/ipa-tvos && zip -qry ../Lanterna-tvOS.ipa Payload
	@echo "Built $(BUILD)/Lanterna-tvOS.ipa (unsigned). Upload it in the atvloadly web UI."

ipa-ios: gen
	xcodebuild -project Lanterna.xcodeproj -scheme Lanterna-iOS -configuration Release -sdk iphoneos \
	  -derivedDataPath $(BUILD)/dd CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build
	rm -rf $(BUILD)/ipa-ios && mkdir -p $(BUILD)/ipa-ios/Payload
	cp -R $(BUILD)/dd/Build/Products/Release-iphoneos/Lanterna.app $(BUILD)/ipa-ios/Payload/
	cd $(BUILD)/ipa-ios && zip -qry ../Lanterna-iOS.ipa Payload
	@echo "Built $(BUILD)/Lanterna-iOS.ipa (unsigned). Install it through AltStore."

# Mac app, signed ad hoc so it runs on the Mac that built it. Quarantine does not apply to a local build.
app-macos: gen
	xcodebuild -project Lanterna.xcodeproj -scheme Lanterna-macOS -configuration Release -destination 'platform=macOS' \
	  -derivedDataPath $(BUILD)/mac-dd CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=YES build
	rm -rf $(BUILD)/Lanterna.app $(BUILD)/Lanterna-macOS.zip
	cp -R $(BUILD)/mac-dd/Build/Products/Release/Lanterna.app $(BUILD)/Lanterna.app
	cd $(BUILD) && ditto -c -k --keepParent Lanterna.app Lanterna-macOS.zip
	@echo "Built $(BUILD)/Lanterna.app and $(BUILD)/Lanterna-macOS.zip (ad hoc signed). Run: make install-macos"

install-macos: app-macos
	rm -rf /Applications/Lanterna.app && cp -R $(BUILD)/Lanterna.app /Applications/Lanterna.app
	@echo "Installed /Applications/Lanterna.app"

clean:
	rm -rf $(BUILD) Lanterna.xcodeproj
