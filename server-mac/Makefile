APP_NAME    = RemoteDisplayServer
BUNDLE_NAME = Remote Display Server
OUT_DIR     = .build
BUILD_DIR   = .build/apple/Products/Release
BINARY      = $(BUILD_DIR)/$(APP_NAME)
APP_BUNDLE  = $(OUT_DIR)/$(BUNDLE_NAME).app
CONTENTS    = $(APP_BUNDLE)/Contents
MACOS_DIR   = $(CONTENTS)/MacOS
RES_DIR     = $(CONTENTS)/Resources
INFO_PLIST  = Info.plist

# The engine binary (server, no flutter). Built separately with:
#   cargo build --release --bin rustdesk   (in the fork)
# Copied into the bundle as remotedisplayd.
ENGINE_BIN ?= $(HOME)/dev/rustdesk/target/release/rustdesk

# STABLE signing identity (TCC permissions survive rebuilds), chosen by TEAM through
# sign-identity.sh: Sam's personal team only (Developer ID Application if present,
# else Apple Development). Never the first "Apple Development" match — on this Mac
# that was the certificate of another organisation. Stable signing + SAME identity for
# app and engine = a single permission that persists. Override with SIGN_ID=... or TEAM_ID=...
TEAM_ID ?= K45698KZ4W
SIGN_ID ?= $(shell ./sign-identity.sh $(TEAM_ID))
CODE_ID := app.remotedisplay.server
# Explicit designated requirement keyed on identifier + team only. codesign's default one also
# pins the certificate KIND (Apple Development vs Developer ID), and TCC stores that requirement
# when a permission is granted: switching kinds would invalidate Screen Recording and
# Accessibility. With this requirement a development build and a notarized Developer ID build
# are interchangeable. --timestamp: secure timestamp, required by notarization.
SIGN_FLAGS := --sign "$(SIGN_ID)" --identifier "$(CODE_ID)" --options runtime --timestamp \
  --requirements '=designated => identifier "$(CODE_ID)" and anchor apple generic and certificate leaf[subject.OU] = "$(TEAM_ID)"' \
  --force

# Remote Display Camera, the camera extension (spec, Packaging; decisions 0010, 0019).
# Installing it takes a restricted entitlement, which works only with a provisioning
# profile, and each profile matches one kind of certificate. So the extension is bundled
# only when both profiles for SIGN_ID's certificate are given:
#   make APP_PROFILE=server.provisionprofile EXT_PROFILE=camera.provisionprofile
# Without them the build leaves it out, and Setup's Camera row says so.
APP_PROFILE ?=
EXT_PROFILE ?=
EXT_ID      := $(CODE_ID).camera
EXT_BUNDLE   = $(CONTENTS)/Library/SystemExtensions/$(EXT_ID).systemextension
CAMERA_DIR   = $(OUT_DIR)/camera
CAMERA_BIN   = $(CAMERA_DIR)/$(EXT_ID)
CAMERA      := $(if $(and $(strip $(SIGN_ID)),$(APP_PROFILE),$(EXT_PROFILE)),yes,no)
# The app takes the install entitlement only in builds that bundle the extension.
APP_ENTITLEMENTS = $(if $(filter yes,$(CAMERA)),$(CAMERA_DIR)/app.entitlements,Entitlements.plist)
# The extension carries the app's version, so a new app version updates it.
VERSION       := $(shell /usr/libexec/PlistBuddy -c 'Print CFBundleVersion' $(INFO_PLIST))
SHORT_VERSION := $(shell /usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' $(INFO_PLIST))
# Remote Display Microphone, the virtual mic (spec, Packaging; decisions 0013, 0027): a
# HAL plug-in built from BlackHole's unmodified source with these constants, the ones
# the Phase 0 harness measured (docs/tests/virtual-mic/harness). An input-only device
# apps read, and its hidden output-only twin that remotedisplayd plays into; BlackHole
# mirrors one into the other. It needs no provisioning profile, so every build bundles
# it, and Setup's Microphone row copies it to /Library/Audio/Plug-Ins/HAL.
DRIVER_NAME   := RemoteDisplayMicrophone
DRIVER_ID     := $(CODE_ID).mic
DRIVER_DIR     = $(OUT_DIR)/driver
DRIVER_BIN     = $(DRIVER_DIR)/$(DRIVER_NAME)
DRIVER_BUNDLE  = $(CONTENTS)/Library/Audio/Plug-Ins/HAL/$(DRIVER_NAME).driver
DRIVER_DEFINES := \
  -DkDriver_Name='"$(DRIVER_NAME)"' \
  -DkPlugIn_BundleID='"$(DRIVER_ID)"' \
  -DkPlugIn_Icon='"RemoteDisplay.icns"' \
  -DkManufacturer_Name='"Remote Display"' \
  -DkHas_Driver_Name_Format=false \
  -DkDevice_Name='"Remote Display Microphone"' \
  -DkDevice_IsHidden=false -DkDevice_HasInput=true -DkDevice_HasOutput=false \
  -DkDevice2_Name='"Remote Display Microphone Feeder"' \
  -DkDevice2_IsHidden=true -DkDevice2_HasInput=false -DkDevice2_HasOutput=true \
  -DkNumber_Of_Channels=2 -DkSampleRates=48000 \
  -DkCanBeDefaultDevice=false -DkCanBeDefaultSystemDevice=false

# $(call fill,template,output): substitute the team and version placeholders.
fill = sed -e 's/@TEAM_ID@/$(TEAM_ID)/g' -e 's/@VERSION@/$(VERSION)/g' \
  -e 's/@SHORT_VERSION@/$(SHORT_VERSION)/g' "$(1)" > "$(2)"

.PHONY: all build camera driver bundle sign run clean

all: sign

build:
	@swift build -c release --arch arm64 --arch x86_64

# The extension, universal like the app, built with swiftc as in the Phase 0 harness.
camera:
	@mkdir -p "$(CAMERA_DIR)"
	@for arch in arm64 x86_64; do \
	  swiftc -O -target $$arch-apple-macos14.0 -module-name RemoteDisplayCamera \
	    -o "$(CAMERA_DIR)/camera-$$arch" CameraExtension/*.swift || exit 1; \
	done
	@lipo -create -output "$(CAMERA_BIN)" "$(CAMERA_DIR)/camera-arm64" "$(CAMERA_DIR)/camera-x86_64"

# The driver, universal, built as the Phase 0 harness builds it. Our names have no %d for
# the channel count BlackHole formats into them, so clang warns once per name; harmless.
driver:
	@mkdir -p "$(DRIVER_DIR)"
	@xcrun clang -O2 -bundle -arch arm64 -arch x86_64 -mmacosx-version-min=12.0 -Wno-format-extra-args \
	  $(DRIVER_DEFINES) AudioDriver/BlackHole/BlackHole.c -o "$(DRIVER_BIN)" \
	  -framework CoreAudio -framework CoreFoundation -framework Accelerate

bundle: build driver $(if $(filter yes,$(CAMERA)),camera)
	@rm -rf "$(APP_BUNDLE)"
	@mkdir -p "$(MACOS_DIR)" "$(RES_DIR)"
	@cp "$(BINARY)" "$(MACOS_DIR)/$(APP_NAME)"
	@test -x "$(ENGINE_BIN)" || { echo "ERROR: ENGINE_BIN=$(ENGINE_BIN) does not exist (build the engine first)"; exit 1; }
	@cp "$(ENGINE_BIN)" "$(MACOS_DIR)/remotedisplayd"
	@chmod +x "$(MACOS_DIR)/remotedisplayd"
	@cp "$(INFO_PLIST)" "$(CONTENTS)/Info.plist"
	@test -f AppIcon.icns && cp AppIcon.icns "$(RES_DIR)/AppIcon.icns" || true
	@mkdir -p "$(DRIVER_BUNDLE)/Contents/MacOS" "$(DRIVER_BUNDLE)/Contents/Resources"
	@cp "$(DRIVER_BIN)" "$(DRIVER_BUNDLE)/Contents/MacOS/$(DRIVER_NAME)"
	@cp AudioDriver/Info.plist "$(DRIVER_BUNDLE)/Contents/Info.plist"
	@test -f AppIcon.icns && cp AppIcon.icns "$(DRIVER_BUNDLE)/Contents/Resources/RemoteDisplay.icns" || true
	@echo "Bundled Remote Display Microphone ($(DRIVER_ID))"
ifeq ($(CAMERA),yes)
	@test -f "$(APP_PROFILE)" || { echo "ERROR: APP_PROFILE=$(APP_PROFILE) does not exist"; exit 1; }
	@test -f "$(EXT_PROFILE)" || { echo "ERROR: EXT_PROFILE=$(EXT_PROFILE) does not exist"; exit 1; }
	@mkdir -p "$(EXT_BUNDLE)/Contents/MacOS"
	@cp "$(CAMERA_BIN)" "$(EXT_BUNDLE)/Contents/MacOS/$(EXT_ID)"
	@$(call fill,CameraExtension/Info.plist,$(EXT_BUNDLE)/Contents/Info.plist)
	@cp "$(EXT_PROFILE)" "$(EXT_BUNDLE)/Contents/embedded.provisionprofile"
	@cp "$(APP_PROFILE)" "$(CONTENTS)/embedded.provisionprofile"
	@echo "Bundled Remote Display Camera ($(EXT_ID))"
else ifneq ($(APP_PROFILE)$(EXT_PROFILE),)
	@echo "WARNING: Remote Display Camera needs SIGN_ID, APP_PROFILE and EXT_PROFILE together; left out of this build"
else
	@echo "No provisioning profiles: Remote Display Camera is left out of this build"
endif
	@echo "Built $(APP_BUNDLE)"

sign: bundle
ifeq ($(strip $(SIGN_ID)),)
	@echo "WARNING: no stable identity — ad-hoc signing (TCC permissions are invalidated on every rebuild)"
	@# --deep doesn't count Library/Audio as nested code, so the driver is signed on its own.
	@codesign --sign - --identifier "$(DRIVER_ID)" --options runtime --force "$(DRIVER_BUNDLE)"
	@codesign --sign - --options runtime --entitlements Entitlements.plist --force --deep "$(APP_BUNDLE)"
else
	@echo "Signing with stable identity: $(SIGN_ID)  (id=$(CODE_ID))"
	@./unlock-signing-keychain.sh || true
ifeq ($(CAMERA),yes)
	@$(call fill,CameraExtension/Extension.entitlements,$(CAMERA_DIR)/camera.entitlements)
	@$(call fill,App.entitlements,$(CAMERA_DIR)/app.entitlements)
	@# The extension first, on its own, with its own identifier; never --deep (decision 0010).
	@codesign --sign "$(SIGN_ID)" --identifier "$(EXT_ID)" --options runtime --timestamp \
	  --entitlements "$(CAMERA_DIR)/camera.entitlements" --force "$(EXT_BUNDLE)"
endif
	@# The driver on its own too, with its own identifier: coreaudiod loads it, not the app,
	@# and codesign doesn't count Library/Audio as nested code.
	@codesign --sign "$(SIGN_ID)" --identifier "$(DRIVER_ID)" --options runtime --timestamp \
	  --force "$(DRIVER_BUNDLE)"
	@codesign $(SIGN_FLAGS) --entitlements Entitlements.plist "$(MACOS_DIR)/remotedisplayd"
	@codesign $(SIGN_FLAGS) --entitlements "$(APP_ENTITLEMENTS)" "$(MACOS_DIR)/$(APP_NAME)"
	@codesign $(SIGN_FLAGS) --entitlements "$(APP_ENTITLEMENTS)" "$(APP_BUNDLE)"
	@codesign --verify --deep --strict "$(APP_BUNDLE)"
endif
	@xattr -dr com.apple.quarantine "$(APP_BUNDLE)" 2>/dev/null || true
	@echo "Signed $(APP_BUNDLE)"

run: sign
	@open "$(APP_BUNDLE)"

clean:
	@rm -rf $(OUT_DIR)
