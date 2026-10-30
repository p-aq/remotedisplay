# Phase 2 controller-microphone harness (issue #3): runs the engine's microphone tests
# (src/client/device_forward/mic.rs, src/client/device_forward.rs) from their own app
# bundle, so macOS asks about the microphone for the bundle, not the terminal; and builds
# rd-voice-probe.app, which measures Apple's voice processing (decision 0023). See
# ../README.md.
#
#   source <toolchains>/env.sh
#   make            build/rd-mic-capture-probe.app around the engine's test binary, and
#                   build/rd-voice-probe.app with the speech it plays
#   ./gate.sh       the tests in order, with the prompts to answer
#   make list       the microphones that can be forwarded (needs no microphone access)
#   make nothing    without microphone access, nothing is captured
#   make ask        macOS's microphone prompt for the probe; waits up to 5 minutes
#   make sends      10 ms Opus frames from the microphone; a tone through the speaker is heard
#   make forwards   the controller's sender (src/client/device_forward.rs) with the microphone
#   make unplug     the sender with the microphone, which a person unplugs within a minute
#   make voice      rd-voice-probe: Apple's voice processing, speaking through the speaker
#   make revoke     forget both probes' microphone access
#   make clean      revoke, unregister and delete build/ and the logs
#
# MIC= and SPEAKER= name the input and output as `make list` shows them (the defaults
# otherwise). For an echo, pick a microphone that hears the speaker: not a headset's.

SIGN_ID    ?=
MIC        ?=
SPEAKER    ?=
ENGINE     := ../../../../engine/rustdesk
FEATURES   := hwcodec,screencapturekit
BUILD      := $(CURDIR)/build
CS_ID      := $(if $(strip $(SIGN_ID)),$(SIGN_ID),-)
BUNDLE_ID  := app.remotedisplay.spike.mic-capture-probe
APP        := $(BUILD)/rd-mic-capture-probe.app
VOICE_ID   := app.remotedisplay.spike.voice-probe
VOICE      := $(BUILD)/rd-voice-probe.app
SPEECH     := $(BUILD)/speech.wav
TESTS      := client::device_forward::mic::capture
LOGS       := $(shell echo $${TMPDIR:-/tmp/})rd-mic-capture-probe
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
CXX        := xcrun clang++ -std=c++17 -fobjc-arc -O2 -Wall -Wextra -Wno-unused-parameter -mmacosx-version-min=14.0

.PHONY: all list nothing ask sends forwards unplug voice run revoke clean

# cargo prints where it put the test binary; the bundle wraps that binary.
all:
	@mkdir -p $(APP)/Contents/MacOS $(VOICE)/Contents/MacOS $(BUILD)/home
	cd $(ENGINE) && cargo test --locked --release --features $(FEATURES) --lib --no-run 2>&1 \
	  | tee $(BUILD)/cargo.log | grep -E '^(error|warning: unused)|Finished|Executable'
	sed -n 's/.*Executable unittests src\/lib.rs (\(.*\))/\1/p' $(BUILD)/cargo.log > $(BUILD)/exe
	cp "$(ENGINE)/$$(cat $(BUILD)/exe)" $(APP)/Contents/MacOS/rd-mic-capture-probe
	cp probe-Info.plist $(APP)/Contents/Info.plist
	plutil -insert LSEnvironment -json '{"HOME":"$(BUILD)/home"}' $(APP)/Contents/Info.plist
	codesign --sign "$(CS_ID)" --identifier $(BUNDLE_ID) --force $(APP)
	$(CXX) voice_probe.mm -o $(VOICE)/Contents/MacOS/rd-voice-probe \
	  -framework AVFoundation -framework AudioToolbox -framework CoreAudio -framework Foundation
	cp voice-Info.plist $(VOICE)/Contents/Info.plist
	codesign --sign "$(CS_ID)" --identifier $(VOICE_ID) --force $(VOICE)
	say -o $(SPEECH) --file-format=WAVE --data-format=LEF32@48000 "This is the Remote Display \
	  echo test. The controller's speakers play the host's sound, and its microphone should \
	  not send that sound back."
	@echo "Built $(APP) and $(VOICE)"

list:
	@$(MAKE) --no-print-directory run TEST=lists_microphones_but_not_ours

nothing:
	@$(MAKE) --no-print-directory run TEST=nothing_without_microphone_access

ask:
	@$(MAKE) --no-print-directory run TEST=asks_for_microphone_access WAIT=310

sends:
	@$(MAKE) --no-print-directory run TEST=sends_the_microphone_as_opus

forwards:
	@$(MAKE) --no-print-directory run TESTS=client::device_forward::capture TEST=forwards_the_microphone

# Unplug the microphone, or turn the headset off, once the test says so.
unplug:
	@$(MAKE) --no-print-directory run TESTS=client::device_forward::capture \
	  TEST=tells_the_host_when_the_microphone_is_unplugged WAIT=75

# About 40 s, speaking through SPEAKER most of it. The first run asks for the microphone.
voice:
	@mkdir -p $(LOGS) && rm -f $(LOGS)/voice.log
	open -W -n --stdout $(LOGS)/voice.log --stderr $(LOGS)/voice.log $(VOICE) \
	  --args --mic "$(MIC)" --speaker "$(SPEAKER)" --speech $(SPEECH)
	@cat $(LOGS)/voice.log

# `open` makes the bundle its own app, so macOS asks about the microphone for it. The
# bundle's LSEnvironment points HOME into build/, so the engine's config
# (~/Library/Preferences/RemoteDisplay) lands there, however the bundle is launched;
# MIC and SPEAKER reach the tests through `open --env`, which leaves the signed bundle as
# it is. `open --stdout` fails with -10810 for a file on an external drive, so the logs go
# to the system temp folder; `-W` can't always find the process, so wait for libtest's
# last line.
WAIT ?= 40
run:
	@mkdir -p $(LOGS) && rm -f $(LOGS)/out.log $(LOGS)/err.log
	open -W -n --stdout $(LOGS)/out.log --stderr $(LOGS)/err.log \
	  --env "RD_MIC=$(MIC)" --env "RD_SPEAKER=$(SPEAKER)" \
	  $(APP) --args $(TESTS)::$(TEST) --ignored --nocapture --test-threads=1
	@for i in $$(seq $$(( $(WAIT) * 2 ))); do grep -q '^test result:' $(LOGS)/out.log 2> /dev/null && break; sleep 0.5; done
	@cat $(LOGS)/err.log $(LOGS)/out.log
	@grep -q '^test result: ok. 1 passed' $(LOGS)/out.log

# tccutil finds a bundle through Launch Services, so register it first.
revoke:
	$(LSREGISTER) -f $(APP)
	$(LSREGISTER) -f $(VOICE)
	tccutil reset Microphone $(BUNDLE_ID)
	tccutil reset Microphone $(VOICE_ID)

clean: revoke
	$(LSREGISTER) -u $(APP)
	$(LSREGISTER) -u $(VOICE)
	rm -rf $(BUILD) $(LOGS)
