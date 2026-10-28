# Phase 1 controller-camera harness (issue #2): runs the engine's camera tests
# (src/platform/macos_camera_capture.rs, src/client/device_forward.rs) from their own app bundle, so macOS asks about
# the camera for the bundle, not the terminal, then decodes what they sent with the
# host's decoder from ../../camera-extension/harness. See ../README.md.
#
#   source <toolchains>/env.sh
#   make            build/rd-camera-probe.app around the engine's test binary, and the decoder
#   ./gate.sh       the tests in order, with the prompt to answer
#   make list       the cameras that can be forwarded (needs no camera access)
#   make nothing    without camera access, nothing is captured
#   make ask        macOS's camera prompt for the probe; waits up to 5 minutes for the answer
#   make sends      720p H.264 from the camera, then decoded by the host's decoder
#   make forwards   the controller's sender (src/client/device_forward.rs) with the camera
#   make revoke     forget the probe's camera access
#   make clean      revoke, unregister and delete build/ and the captured frames

SIGN_ID   ?=
ENGINE    := ../../../../engine/rustdesk
CODEC     := ../../camera-extension/harness
FEATURES  := hwcodec,screencapturekit
BUILD     := $(CURDIR)/build
CS_ID     := $(if $(strip $(SIGN_ID)),$(SIGN_ID),-)
BUNDLE_ID := app.remotedisplay.spike.camera-probe
APP       := $(BUILD)/rd-camera-probe.app
DECODE    := $(BUILD)/rd-camera-decode
TESTS     := platform::macos_camera_capture::capture
LOGS      := $(shell echo $${TMPDIR:-/tmp/})rd-camera-probe
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
# Same language mode as the engine's build.rs (no ARC).
CXX       := xcrun clang++ -std=c++17 -O2 -Wall -Wextra -Wno-unused-parameter -mmacosx-version-min=14.0

.PHONY: all list nothing ask sends forwards run revoke clean

# cargo prints where it put the test binary; the bundle wraps that binary.
all:
	@mkdir -p $(APP)/Contents/MacOS $(BUILD)/home
	cd $(ENGINE) && cargo test --locked --release --features $(FEATURES) --lib --no-run 2>&1 \
	  | tee $(BUILD)/cargo.log | grep -E '^(error|warning: unused)|Finished|Executable'
	sed -n 's/.*Executable unittests src\/lib.rs (\(.*\))/\1/p' $(BUILD)/cargo.log > $(BUILD)/exe
	cp "$(ENGINE)/$$(cat $(BUILD)/exe)" $(APP)/Contents/MacOS/rd-camera-probe
	cp probe-Info.plist $(APP)/Contents/Info.plist
	plutil -insert LSEnvironment -json '{"HOME":"$(BUILD)/home"}' $(APP)/Contents/Info.plist
	codesign --sign "$(CS_ID)" --identifier $(BUNDLE_ID) --force $(APP)
	$(CXX) $(CODEC)/camera_codec.mm decode.mm -o $(DECODE) -framework CoreFoundation -framework CoreMedia \
	  -framework CoreVideo -framework VideoToolbox -framework CoreImage -framework CoreGraphics -framework Foundation
	@echo "Built $(APP) and $(DECODE)"

list:
	@$(MAKE) --no-print-directory run TEST=lists_cameras_but_not_ours

nothing:
	@$(MAKE) --no-print-directory run TEST=nothing_without_camera_access

ask:
	@$(MAKE) --no-print-directory run TEST=asks_for_camera_access WAIT=310

# The test writes what it received to $(LOGS)/stream.bin; the decoder reads it back.
sends:
	@$(MAKE) --no-print-directory run TEST=sends_the_camera_as_h264
	$(DECODE) $(LOGS)/stream.bin $(LOGS)/frame.png
	@echo "Last frame: $(LOGS)/frame.png (deleted by make clean)"

forwards:
	@$(MAKE) --no-print-directory run TESTS=client::device_forward::capture TEST=forwards_the_camera

# `open` makes the bundle its own app, so macOS asks about the camera for it. The
# bundle's LSEnvironment points HOME into build/, so the engine's config
# (~/Library/Preferences/RemoteDisplay) lands there, however the bundle is launched.
# `open --stdout` fails with -10810 for a file on an external drive, so the logs go to the
# system temp folder; `-W` can't always find the process, so wait for libtest's last line.
WAIT ?= 40
run:
	@mkdir -p $(LOGS) && rm -f $(LOGS)/out.log $(LOGS)/err.log
	open -W -n --stdout $(LOGS)/out.log --stderr $(LOGS)/err.log \
	  $(APP) --args $(TESTS)::$(TEST) --ignored --nocapture --test-threads=1
	@for i in $$(seq $$(( $(WAIT) * 2 ))); do grep -q '^test result:' $(LOGS)/out.log 2> /dev/null && break; sleep 0.5; done
	@cat $(LOGS)/err.log $(LOGS)/out.log
	@grep -q '^test result: ok. 1 passed' $(LOGS)/out.log

# tccutil finds the bundle through Launch Services, so register it first.
revoke:
	$(LSREGISTER) -f $(APP)
	tccutil reset Camera $(BUNDLE_ID)

clean: revoke
	$(LSREGISTER) -u $(APP)
	rm -rf $(BUILD) $(LOGS)
