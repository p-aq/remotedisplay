# Phase 1 host-camera harness (issue #2): checks the engine's decoder, letterbox and sink
# code (engine/rustdesk/src/platform/macos_camera_sink.mm) with streams from the measured
# encoder in ../../camera-extension/harness. Needs no signing, camera or camera
# extension. See ../README.md.
#
#   make test        the checks, with 3,000 fuzzed access units
#   make test-asan   the same under AddressSanitizer and UndefinedBehaviorSanitizer, with
#                    20,000 (decision 0016: required whenever the decoder changes)
#   make clean

ENGINE     := ../../../../engine/rustdesk/src/platform/macos_camera_sink.mm
CODEC      := ../../camera-extension/harness
BUILD      := build
SOURCES    := $(ENGINE) $(CODEC)/camera_codec.mm $(CODEC)/test_card.mm sink_test.mm
FRAMEWORKS := -framework CoreFoundation -framework CoreMedia -framework CoreMediaIO -framework CoreVideo \
              -framework VideoToolbox -framework CoreGraphics -framework CoreText
# Same language mode as the engine's build.rs (no ARC).
CXX        := xcrun clang++ -std=c++17 -Wall -Wextra -Wno-unused-parameter -mmacosx-version-min=14.0

.PHONY: test test-asan clean

test:
	@mkdir -p $(BUILD)
	$(CXX) -O2 $(SOURCES) -o $(BUILD)/rd-camera-sink-test $(FRAMEWORKS)
	$(BUILD)/rd-camera-sink-test

test-asan:
	@mkdir -p $(BUILD)
	$(CXX) -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer $(SOURCES) \
	  -o $(BUILD)/rd-camera-sink-test-asan $(FRAMEWORKS)
	$(BUILD)/rd-camera-sink-test-asan --fuzz 20000

clean:
	rm -rf $(BUILD)
