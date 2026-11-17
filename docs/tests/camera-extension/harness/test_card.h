// The Remote Display test card: grey background, a moving bar, a millisecond clock and
// red/green/blue bands, in NV12 (420v) IOSurface-backed pixel buffers.

#pragma once

#include <CoreVideo/CoreVideo.h>

#ifdef __cplusplus
extern "C" {
#endif

CVPixelBufferPoolRef TestCardMakePool(int width, int height);

// Renders frame number `frame` (the bar moves 8 pixels per frame). +1 reference, or NULL.
CVPixelBufferRef TestCardRender(CVPixelBufferPoolRef pool, int frame);

#ifdef __cplusplus
}
#endif
