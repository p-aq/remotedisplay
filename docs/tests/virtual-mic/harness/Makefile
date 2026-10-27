# Phase 0 microphone harness (issue #1): both ways of publishing "Remote Display
# Microphone", a test-signal feeder and a probe. Builds with the Command Line Tools,
# like ../../camera-extension/harness. See ../README.md.
#
#   make                         feeder, probe and the Option A driver
#   sudo make install-driver     Option A: install the driver and restart coreaudiod
#   build/rd-mic-feeder --option a   (or b)   then, in another terminal:
#   build/rd-mic-probe --seconds 10

SIGN_ID     ?=
ARCH        ?= arm64

CXX         := xcrun clang++ -std=c++17 -O2 -Wall -Wextra -Wno-unused-parameter -arch $(ARCH) -mmacosx-version-min=14.2
FRAMEWORKS  := -framework CoreFoundation -framework CoreAudio -framework Foundation
BUILD       := build
CS_ID       := $(if $(strip $(SIGN_ID)),$(SIGN_ID),-)
FEEDER      := $(BUILD)/rd-mic-feeder
PROBE       := $(BUILD)/rd-mic-probe

# Option A is a BlackHole build configured, not modified (decision 0015): fetched at a
# pinned commit rather than copied into this repo.
BLACKHOLE_URL    := https://github.com/ExistentialAudio/BlackHole.git
BLACKHOLE_TAG    := v0.7.2
BLACKHOLE_COMMIT := 561d934c77a1fa64987e01ccabe890fed30e181f
BLACKHOLE        := $(BUILD)/BlackHole
DRIVER_NAME      := RemoteDisplayMicrophone
DRIVER           := $(BUILD)/$(DRIVER_NAME).driver
HAL_DIR          := /Library/Audio/Plug-Ins/HAL
# A visible input-only device that apps read, and its hidden output-only twin that
# remotedisplayd plays into. BlackHole mirrors one into the other (decision 0013).
DRIVER_DEFINES   := \
  -DkDriver_Name='"$(DRIVER_NAME)"' \
  -DkPlugIn_BundleID='"app.remotedisplay.spike.mic"' \
  -DkPlugIn_Icon='"RemoteDisplay.icns"' \
  -DkManufacturer_Name='"Remote Display"' \
  -DkHas_Driver_Name_Format=false \
  -DkDevice_Name='"Remote Display Microphone"' \
  -DkDevice_IsHidden=false -DkDevice_HasInput=true -DkDevice_HasOutput=false \
  -DkDevice2_Name='"Remote Display Microphone Feeder"' \
  -DkDevice2_IsHidden=true -DkDevice2_HasInput=false -DkDevice2_HasOutput=true \
  -DkNumber_Of_Channels=2 -DkSampleRates=48000 \
  -DkCanBeDefaultDevice=false -DkCanBeDefaultSystemDevice=false

.PHONY: all feeder probe driver install-driver uninstall-driver list clean

all: feeder probe driver

feeder:
	@mkdir -p $(BUILD)
	$(CXX) mic_sink.mm mic_feeder.mm -o $(FEEDER) $(FRAMEWORKS) \
	  -Wl,-sectcreate,__TEXT,__info_plist,feeder-Info.plist
	codesign --sign "$(CS_ID)" --identifier app.remotedisplay.spike.mic-feeder --options runtime --force $(FEEDER)

probe:
	@mkdir -p $(BUILD)
	$(CXX) mic_sink.mm mic_probe.mm -o $(PROBE) $(FRAMEWORKS) \
	  -Wl,-sectcreate,__TEXT,__info_plist,probe-Info.plist
	@# Hardened runtime blocks audio input without this entitlement.
	codesign --sign "$(CS_ID)" --identifier app.remotedisplay.spike.mic-probe --options runtime \
	  --entitlements probe.entitlements --force $(PROBE)

$(BLACKHOLE):
	git clone --quiet --depth 1 --branch $(BLACKHOLE_TAG) $(BLACKHOLE_URL) $(BLACKHOLE)
	@test "$$(git -C $(BLACKHOLE) rev-parse HEAD)" = "$(BLACKHOLE_COMMIT)" || \
	  { echo "BlackHole $(BLACKHOLE_TAG) is not commit $(BLACKHOLE_COMMIT); refusing to build"; rm -rf $(BLACKHOLE); exit 1; }

driver: $(BLACKHOLE)
	@rm -rf $(DRIVER)
	@mkdir -p $(DRIVER)/Contents/MacOS $(DRIVER)/Contents/Resources
	xcrun clang -O2 -bundle -arch arm64 -arch x86_64 -mmacosx-version-min=12.0 $(DRIVER_DEFINES) \
	  $(BLACKHOLE)/BlackHole/BlackHole.c -o $(DRIVER)/Contents/MacOS/$(DRIVER_NAME) \
	  -framework CoreAudio -framework CoreFoundation -framework Accelerate
	@cp driver/Info.plist $(DRIVER)/Contents/Info.plist
	@cp ../../../../server-mac/AppIcon.icns $(DRIVER)/Contents/Resources/RemoteDisplay.icns
	codesign --sign "$(CS_ID)" --identifier app.remotedisplay.spike.mic --options runtime --force $(DRIVER)
	@echo "Built $(DRIVER)"

# Needs an admin: copies into /Library and restarts coreaudiod (decision 0013). Touches
# only our own bundle name. `launchctl kickstart -k` is refused while SIP is on
# (macOS 15.7, error 150); killing coreaudiod lets launchd restart it, as BlackHole's
# own installer does.
install-driver:
	@test -d $(DRIVER) || { echo "run make driver first"; exit 1; }
	rm -rf "$(HAL_DIR)/$(DRIVER_NAME).driver"
	cp -R $(DRIVER) "$(HAL_DIR)/"
	killall coreaudiod

uninstall-driver:
	rm -rf "$(HAL_DIR)/$(DRIVER_NAME).driver"
	killall coreaudiod

list:
	$(PROBE) --list

clean:
	rm -rf $(BUILD)
