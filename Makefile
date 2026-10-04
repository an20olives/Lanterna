.RECIPEPREFIX = >
BUILD := build

.PHONY: gen ipa-tvos ipa-ios clean

gen:
> xcodegen generate

ipa-tvos: gen
> xcodebuild -project Lanterna.xcodeproj -scheme Lanterna-tvOS -configuration Release -sdk appletvos \
>   -derivedDataPath $(BUILD)/dd CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build
> rm -rf $(BUILD)/ipa-tvos && mkdir -p $(BUILD)/ipa-tvos/Payload
> cp -R $(BUILD)/dd/Build/Products/Release-appletvos/Lanterna.app $(BUILD)/ipa-tvos/Payload/
> cd $(BUILD)/ipa-tvos && zip -qry ../Lanterna-tvOS.ipa Payload
> @echo "Built $(BUILD)/Lanterna-tvOS.ipa (unsigned). Upload it in the atvloadly web UI."

ipa-ios: gen
> xcodebuild -project Lanterna.xcodeproj -scheme Lanterna-iOS -configuration Release -sdk iphoneos \
>   -derivedDataPath $(BUILD)/dd CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build
> rm -rf $(BUILD)/ipa-ios && mkdir -p $(BUILD)/ipa-ios/Payload
> cp -R $(BUILD)/dd/Build/Products/Release-iphoneos/Lanterna.app $(BUILD)/ipa-ios/Payload/
> cd $(BUILD)/ipa-ios && zip -qry ../Lanterna-iOS.ipa Payload
> @echo "Built $(BUILD)/Lanterna-iOS.ipa (unsigned). Install it through AltStore."

clean:
> rm -rf $(BUILD) Lanterna.xcodeproj
