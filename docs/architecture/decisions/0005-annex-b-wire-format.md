# 0005. H.264 Annex B on the wire

- **Status:** Accepted, 2026-10-24 (review finding V-4; PR #16)
- **Original design:** Extends the spec, which didn't state the bitstream format.

## Context

FFmpeg and hwcodec emit Annex B (start codes, parameter sets in band).
`VTCompressionSession` emits AVCC (length-prefixed NAL units, parameter sets in the
format description), and `VTDecompressionSession` only decodes AVCC with a format
description built from SPS and PPS.

## Decision

`CameraFrame` carries H.264 Annex B, one access unit per `EncodedVideoFrame`, with SPS
and PPS in front of every key frame. The macOS controller converts its AVCC output
before sending. The host parses SPS and PPS on key frames, rebuilds the format
description when they change, and rewrites start codes as 4-byte lengths before
decoding; until its first key frame it drops frames and asks for one.

## Consequences

- One wire format for every controller: a Windows controller (Phase 4) can send what
  hwcodec already produces.
- Conversion code on both macOS ends, small and testable with fuzzed input.
