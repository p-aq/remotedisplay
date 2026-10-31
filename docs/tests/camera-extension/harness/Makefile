# Phase 0 camera harness (issue #1): camera extension, container app and test-card
# feeder. Builds with the Command Line Tools alone, like server-mac/Makefile; no Xcode
# project. See ../README.md.
#
#   make                       ad-hoc build: compiles and bundles; macOS won't activate it
#   make SIGN_ID="Apple Development: …" TEAM_ID=ABCDE12345 \
#        APP_PROFILE=app.provisionprofile EXT_PROFILE=ext.provisionprofile
#   make install activate      copy to /Applications, then ask macOS to activate
#   make feed FEED_ARGS="--seconds 30"
#   make codec-test            H.264 encode → Annex B → decode checks (no signing needed)
#   make codec-test-asan       the same under AddressSanitizer, with 20,000 fuzzed frames
#   make format-test           server-mac's source stream wraps decoded frames (no signing needed)

TEAM_ID     ?=
SIGN_ID     ?=
APP_PROFILE ?=
EXT_PROFILE ?=
# Bump to test extension updates (Photo Booth may keep the old one until it relaunches).
VERSION     ?= 1
ARCH        ?= arm64
FEED_ARGS   ?=

SWIFTC      := swiftc -O -target $(ARCH)-apple-macos14.0
# Same language mode as the engine's build.rs uses for src/platform/macos.mm (no ARC).
CXX         := xcrun clang++ -std=c++17 -O2 -Wall -Wextra -Wno-unused-parameter -arch $(ARCH) -mmacosx-version-min=14.0
FRAMEWORKS  := -framework CoreFoundation -framework CoreMedia -framework CoreMediaIO -framework CoreVideo \
               -framework CoreGraphics -framework CoreText -framework ImageIO
CODEC_FRAMEWORKS := -framework CoreFoundation -framework CoreMedia -framework CoreVideo -framework VideoToolbox \
               -framework CoreGraphics -framework CoreText
CODEC_TEST   = $(BUILD)/rd-camera-codec-test
FORMAT_TEST  = $(BUILD)/rd-camera-format-test
SERVER_EXT  := ../../../../server-mac/CameraExtension
BUILD       := build
APP_ID      := app.remotedisplay.spike
EXT_ID      := app.remotedisplay.spike.camera
APP         := $(BUILD)/RDCameraSpike.app
EXT         := $(APP)/Contents/Library/SystemExtensions/$(EXT_ID).systemextension
INSTALLED   := /Applications/RDCameraSpike.app
FEEDER      := $(BUILD)/rd-camera-feeder
FEEDER_BARE := $(BUILD)/rd-camera-feeder-bare

ifeq ($(strip $(SIGN_ID)),)
  SIGNED := no
  TEAM   := ADHOC
  CS_ID  := -
else
  SIGNED := yes
  TEAM   := $(TEAM_ID)
  CS_ID  := $(SIGN_ID)
endif

# $(call fill,template,output): substitute the team and version placeholders.
fill = sed -e 's/@TEAM_ID@/$(TEAM)/g' -e 's/@VERSION@/$(VERSION)/g' "$(1)" > "$(2)"

.PHONY: all camera feeder codec codec-test codec-test-asan format-test check-signing install activate deactivate list feed clean

all: camera feeder codec

check-signing:
ifeq ($(SIGNED),yes)
	@test -n "$(TEAM_ID)" || { echo "TEAM_ID is required with SIGN_ID"; exit 1; }
	@test -f "$(APP_PROFILE)" || { echo "APP_PROFILE (provisioning profile for $(APP_ID)) not found"; exit 1; }
	@test -f "$(EXT_PROFILE)" || { echo "EXT_PROFILE (provisioning profile for $(EXT_ID)) not found"; exit 1; }
endif

camera: check-signing
	@rm -rf "$(APP)"
	@mkdir -p "$(APP)/Contents/MacOS" "$(EXT)/Contents/MacOS"
	$(SWIFTC) -o "$(EXT)/Contents/MacOS/$(EXT_ID)" CameraExtension/main.swift CameraExtension/NV12Canvas.swift
	@$(call fill,CameraExtension/Info.plist,$(EXT)/Contents/Info.plist)
	$(SWIFTC) -o "$(APP)/Contents/MacOS/RDCameraSpike" ContainerApp/main.swift
	@$(call fill,ContainerApp/Info.plist,$(APP)/Contents/Info.plist)
ifeq ($(SIGNED),yes)
	@cp "$(EXT_PROFILE)" "$(EXT)/Contents/embedded.provisionprofile"
	@cp "$(APP_PROFILE)" "$(APP)/Contents/embedded.provisionprofile"
	@$(call fill,CameraExtension/Extension.entitlements,$(BUILD)/ext.entitlements)
	@$(call fill,ContainerApp/App.entitlements,$(BUILD)/app.entitlements)
	@# Extension first, on its own; then the app. No --deep (decision 0010).
	codesign --sign "$(CS_ID)" --identifier $(EXT_ID) --options runtime --timestamp \
	  --entitlements $(BUILD)/ext.entitlements --force "$(EXT)"
	codesign --sign "$(CS_ID)" --identifier $(APP_ID) --options runtime --timestamp \
	  --entitlements $(BUILD)/app.entitlements --force "$(APP)"
else
	@echo "No SIGN_ID: ad-hoc signing without the restricted entitlement. The bundle is"
	@echo "complete, but macOS will refuse to activate the extension (see ../README.md)."
	codesign --sign - --identifier $(EXT_ID) --options runtime \
	  --entitlements CameraExtension/Extension-adhoc.entitlements --force "$(EXT)"
	codesign --sign - --identifier $(APP_ID) --options runtime --force "$(APP)"
endif
	codesign --verify --strict --deep "$(APP)"
	@echo "Built $(APP)"

# Two feeders for issue #7: one with a camera usage string and entitlement, one bare.
feeder:
	@mkdir -p $(BUILD)
	$(CXX) camera_sink.mm test_card.mm feeder.mm -o $(FEEDER) $(FRAMEWORKS) \
	  -Wl,-sectcreate,__TEXT,__info_plist,feeder-Info.plist
	$(CXX) camera_sink.mm test_card.mm feeder.mm -o $(FEEDER_BARE) $(FRAMEWORKS)
	codesign --sign "$(CS_ID)" --identifier $(APP_ID).feeder --options runtime \
	  --entitlements feeder.entitlements --force $(FEEDER)
	codesign --sign "$(CS_ID)" --identifier $(APP_ID).feeder-bare --options runtime --force $(FEEDER_BARE)

codec:
	@mkdir -p $(BUILD)
	$(CXX) camera_codec.mm test_card.mm codec_test.mm -o $(CODEC_TEST) $(CODEC_FRAMEWORKS)

codec-test: codec
	$(CODEC_TEST)
	$(CODEC_TEST) --no-low-latency --fuzz 1000

# The decoder parses untrusted network input: run the fuzz pass under the sanitizers.
codec-test-asan:
	@mkdir -p $(BUILD)
	xcrun clang++ -std=c++17 -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer -arch $(ARCH) \
	  -mmacosx-version-min=14.0 camera_codec.mm test_card.mm codec_test.mm -o $(CODEC_TEST)-asan $(CODEC_FRAMEWORKS)
	$(CODEC_TEST)-asan --fuzz 20000

# Remote Display Camera's source stream, in the server app's extension
# (server-mac/CameraExtension/SourceFormat.swift), with frames tagged as the engine's
# decoder tags them.
format-test:
	@mkdir -p $(BUILD)
	$(SWIFTC) -parse-as-library -o $(FORMAT_TEST) format_test.swift $(SERVER_EXT)/SourceFormat.swift \
	  $(SERVER_EXT)/NV12Canvas.swift
	$(FORMAT_TEST)

install: camera
	rm -rf "$(INSTALLED)"
	cp -R "$(APP)" /Applications/

activate:
	"$(INSTALLED)/Contents/MacOS/RDCameraSpike" --activate

deactivate:
	"$(INSTALLED)/Contents/MacOS/RDCameraSpike" --deactivate

list:
	systemextensionsctl list | grep -A3 cmio || true
	$(FEEDER) --list

feed: feeder
	$(FEEDER) $(FEED_ARGS)

clean:
	rm -rf $(BUILD)
