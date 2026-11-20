# Live-session tools that need building (../README.md); host.sh, controller.sh and
# profiles.sh need nothing built. rd-clap measures how long a controller's microphone
# takes to reach Remote Display Microphone (spec, Testing plan › Mic latency).
#
#   make            build/rd-clap.app
#   make clap-test  rd-clap's onset detection and pairing on generated claps; needs no
#                   microphone
#   make inputs     the inputs rd-clap can use as its reference, and how each connects
#   make latency    on the host, while a controller forwards its microphone: clap next to
#                   the controller's microphone and the reference, every two seconds or so
#   make clean      forget rd-clap's microphone access, unregister it and delete build/
#
# rd-lipsync measures test 10's lip sync from a QuickTime recording on the host (lipsync.m):
#
#   make lipsync-test   writes a clip whose beeps are 120 ms late and measures it
#   make lipsync-clip   build/lipsync-clip.mov: a flash and a beep every second, to play on a
#                       phone in front of the controller's camera and microphone
#   make lipsync MOVIE=…  each flash's offset to its sound, and contact sheets around each
#                       sound onset (for claps) beside the movie
#
# REF= names the reference input as `make inputs` lists it; without it rd-clap takes the
# first built-in or wired input, never a Bluetooth or virtual one. DURATION= is how long
# it records, in seconds (15).

ARCH       ?= arm64
REF        ?=
DURATION   ?= 15
# This folder, wherever make is run from, so clean never deletes another folder's build/.
HERE       := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
ifneq ($(words $(HERE))$(wildcard $(HERE)/clap.m),1$(HERE)/clap.m)
$(error Can't find this Makefile's folder; a path with spaces isn't supported. Got: $(HERE))
endif
BUILD      := $(HERE)/build
BUNDLE_ID  := app.remotedisplay.spike.clap
APP        := $(BUILD)/rd-clap.app
BIN        := $(APP)/Contents/MacOS/rd-clap
LOGS       := $(shell echo $${TMPDIR:-/tmp/})rd-clap
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

.PHONY: all clap-test inputs latency lipsync-test lipsync-clip lipsync clean

all:
	@mkdir -p "$(APP)/Contents/MacOS"
	xcrun clang -fobjc-arc -O2 -Wall -Wextra -arch $(ARCH) -mmacosx-version-min=14.0 "$(HERE)/clap.m" -o "$(BIN)" \
	  -framework AVFoundation -framework AudioToolbox -framework CoreAudio -framework Foundation
	cp "$(HERE)/clap-Info.plist" "$(APP)/Contents/Info.plist"
	codesign --sign - --identifier $(BUNDLE_ID) --force "$(APP)"
	@echo "Built $(APP)"

clap-test: all
	"$(BIN)" --self-test

inputs: all
	"$(BIN)" --list

# `open --stdout` fails with -10810 for a file on an external drive, so the log goes to
# the system temp folder.
latency: all
	@mkdir -p "$(LOGS)" && rm -f "$(LOGS)/clap.log"
	@echo "Clap next to the controller's microphone and the reference, every two seconds or so, for $(DURATION) s."
	open -W -n --stdout "$(LOGS)/clap.log" --stderr "$(LOGS)/clap.log" "$(APP)" \
	  --args $(if $(strip $(REF)),--ref "$(REF)") --seconds $(DURATION)
	@cat "$(LOGS)/clap.log"
	@grep -q '^PASS' "$(LOGS)/clap.log"

LIPSYNC    := $(BUILD)/rd-lipsync

$(LIPSYNC): $(HERE)/lipsync.m
	@mkdir -p "$(BUILD)"
	xcrun clang -fobjc-arc -O2 -Wall -Wextra -arch $(ARCH) -mmacosx-version-min=14.0 "$(HERE)/lipsync.m" -o "$@" \
	  -framework AVFoundation -framework CoreMedia -framework CoreVideo -framework CoreGraphics \
	  -framework CoreText -framework ImageIO -framework UniformTypeIdentifiers -framework Foundation

lipsync-test: $(LIPSYNC)
	"$(LIPSYNC)" --self-test

lipsync-clip: $(LIPSYNC)
	"$(LIPSYNC)" clip "$(BUILD)/lipsync-clip.mov"
	@echo "Wrote $(BUILD)/lipsync-clip.mov"

lipsync: $(LIPSYNC)
	@test -n "$(MOVIE)" || { echo "usage: make lipsync MOVIE=path/to/recording.mov"; exit 2; }
	"$(LIPSYNC)" measure "$(MOVIE)"

# tccutil finds a bundle through Launch Services, so register it first.
clean:
	-$(LSREGISTER) -f "$(APP)"
	-tccutil reset Microphone $(BUNDLE_ID)
	-$(LSREGISTER) -u "$(APP)"
	rm -rf "$(BUILD)" "$(LOGS)"
