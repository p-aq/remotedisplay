# Live-session tools that need building (../README.md); host.sh, controller.sh and
# profiles.sh need nothing built. rd-clap measures how long a controller's microphone
# takes to reach Remote Display Microphone (spec, Testing plan › Mic latency).
#
#   make            build/rd-clap.app
#   make clap-test  rd-clap's onset detection on generated claps; needs no microphone
#   make inputs     the inputs rd-clap can use as its reference
#   make latency    on the host, while a controller forwards its microphone: clap next to
#                   the controller's microphone and the reference, about once a second
#   make clean      forget rd-clap's microphone access, unregister it and delete build/
#
# REF= names the reference input as `make inputs` lists it (the default input otherwise,
# unless that's Remote Display Microphone). DURATION= is how long it records, in seconds
# (15).

ARCH       ?= arm64
REF        ?=
DURATION   ?= 15
BUILD      := $(CURDIR)/build
BUNDLE_ID  := app.remotedisplay.spike.clap
APP        := $(BUILD)/rd-clap.app
BIN        := $(APP)/Contents/MacOS/rd-clap
LOGS       := $(shell echo $${TMPDIR:-/tmp/})rd-clap
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

.PHONY: all clap-test inputs latency clean

all:
	@mkdir -p $(APP)/Contents/MacOS
	xcrun clang -fobjc-arc -O2 -Wall -Wextra -arch $(ARCH) -mmacosx-version-min=14.0 clap.m -o $(BIN) \
	  -framework AVFoundation -framework AudioToolbox -framework CoreAudio -framework Foundation
	cp clap-Info.plist $(APP)/Contents/Info.plist
	codesign --sign - --identifier $(BUNDLE_ID) --force $(APP)
	@echo "Built $(APP)"

clap-test: all
	$(BIN) --self-test

inputs: all
	$(BIN) --list

# `open --stdout` fails with -10810 for a file on an external drive, so the log goes to
# the system temp folder.
latency: all
	@mkdir -p $(LOGS) && rm -f $(LOGS)/clap.log
	@echo "Clap next to the controller's microphone and the reference, about once a second, for $(DURATION) s."
	open -W -n --stdout $(LOGS)/clap.log --stderr $(LOGS)/clap.log $(APP) \
	  --args $(if $(strip $(REF)),--ref "$(REF)") --seconds $(DURATION)
	@cat $(LOGS)/clap.log
	@grep -q '^PASS' $(LOGS)/clap.log

# tccutil finds a bundle through Launch Services, so register it first.
clean:
	-$(LSREGISTER) -f $(APP)
	-tccutil reset Microphone $(BUNDLE_ID)
	-$(LSREGISTER) -u $(APP)
	rm -rf $(BUILD) $(LOGS)
