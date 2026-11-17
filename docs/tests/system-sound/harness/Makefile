# Phase 3 system-sound harness (issue #4): runs the engine's capture tests
# (src/server/audio_service/host_sound.rs) from their own app bundle, so Screen Recording
# is granted to the bundle, not to the terminal. The screencapturekit feature needs full
# Xcode (tools/README.md). See ../README.md.
#
#   source <toolchains>/env.sh
#   make                build/rd-sound-probe.app around the engine's test binary
#   ./gate.sh           the gate tests in order, with the prompts to answer
#   make hears          a tone through the speakers reaches what a controller receives
#   make revoke         forget the probe's Screen Recording grant
#   make nothing        with Screen Recording refused, nothing is sent
#   make own-mic        a controller's microphone, played into Remote Display Microphone,
#                       doesn't come back (needs ../../virtual-mic's driver installed)
#   make clean          revoke, unregister and delete build/

SIGN_ID   ?=
ENGINE    := ../../../../engine/rustdesk
FEATURES  := hwcodec,screencapturekit
BUILD     := $(CURDIR)/build
CS_ID     := $(if $(strip $(SIGN_ID)),$(SIGN_ID),-)
BUNDLE_ID := app.remotedisplay.spike.sound-probe
APP       := $(BUILD)/rd-sound-probe.app
TESTS     := server::audio_service::host_sound::capture
LOGS      := $(shell echo $${TMPDIR:-/tmp/})rd-sound-probe
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

.PHONY: all hears nothing own-mic run revoke clean

# cargo prints where it put the test binary; the bundle wraps that binary.
all:
	@mkdir -p $(APP)/Contents/MacOS $(BUILD)/home
	cd $(ENGINE) && cargo test --locked --release --features $(FEATURES) --lib --no-run 2>&1 \
	  | tee $(BUILD)/cargo.log | grep -E '^(error|warning: unused)|Finished|Executable'
	sed -n 's/.*Executable unittests src\/lib.rs (\(.*\))/\1/p' $(BUILD)/cargo.log > $(BUILD)/exe
	cp "$(ENGINE)/$$(cat $(BUILD)/exe)" $(APP)/Contents/MacOS/rd-sound-probe
	cp probe-Info.plist $(APP)/Contents/Info.plist
	plutil -insert LSEnvironment -json '{"HOME":"$(BUILD)/home"}' $(APP)/Contents/Info.plist
	codesign --sign "$(CS_ID)" --identifier $(BUNDLE_ID) --force $(APP)
	@echo "Built $(APP)"

hears:
	@$(MAKE) --no-print-directory run TEST=controller_hears_system_sound

nothing:
	@$(MAKE) --no-print-directory run TEST=nothing_without_screen_recording

own-mic:
	@$(MAKE) --no-print-directory run TEST=controller_never_hears_its_own_microphone

# `open` makes the bundle its own app, so macOS asks about Screen Recording for it. The
# bundle's LSEnvironment points HOME into build/, so the engine's config
# (~/Library/Preferences/RemoteDisplay) lands there, however the bundle is launched.
# `open --stdout` fails with -10810 for a file on an external drive, so the logs go to the
# system temp folder; `-W` can't always find the process, so wait for libtest's last line.
run:
	@mkdir -p $(LOGS) && rm -f $(LOGS)/out.log $(LOGS)/err.log
	open -W -n --stdout $(LOGS)/out.log --stderr $(LOGS)/err.log \
	  $(APP) --args $(TESTS)::$(TEST) --ignored --nocapture --test-threads=1
	@for i in $$(seq 40); do grep -q '^test result:' $(LOGS)/out.log 2> /dev/null && break; sleep 0.5; done
	@cat $(LOGS)/err.log $(LOGS)/out.log
	@grep -q '^test result: ok. 1 passed' $(LOGS)/out.log

# tccutil finds the bundle through Launch Services, so register it first.
revoke:
	$(LSREGISTER) -f $(APP)
	tccutil reset ScreenCapture $(BUNDLE_ID)

clean: revoke
	$(LSREGISTER) -u $(APP)
	rm -rf $(BUILD) $(LOGS)
