//
//  FrameRefWrapper.h
//  VidCore
//
//  Thread-safe reference wrapper for AVFrame lifetime management
//  Ensures AVFrame stays alive until CVPixelBuffer is released
//

#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

// Forward declare AVFrame to avoid importing FFmpeg headers in .h
struct AVFrame;

NS_ASSUME_NONNULL_BEGIN

/// Thread-safe wrapper that manages AVFrame lifetime for zero-copy
/// CVPixelBuffer wrapping.
///
/// This class bridges FFmpeg's reference-counted AVFrame with CoreVideo's
/// CVPixelBuffer, ensuring the underlying frame data remains valid until
/// rendering completes.
///
/// ## Thread Safety
/// - Creation: Decode thread
/// - Retention: CVPixelBuffer holds strong reference via release callback
/// - Release: Any thread (when CVPixelBuffer refcount reaches zero)
///
/// Uses FFmpeg's atomic reference counting (`av_frame_ref`/`av_frame_unref`)
/// for thread-safe memory management.
@interface FrameRefWrapper : NSObject

/// The wrapped AVFrame (read-only).
/// Do not manually free - managed by wrapper lifecycle.
@property(nonatomic, assign, readonly) struct AVFrame *frame;

/// Creates a wrapper that retains the given AVFrame.
/// @param frame The AVFrame to wrap (will be ref-counted via av_frame_ref)
- (instancetype)initWithFrame:(struct AVFrame *)frame;

/// CVPixelBuffer release callback - called when pixel buffer is deallocated.
/// Transfers ownership back to ARC which triggers av_frame_unref.
/// Signature must match CVPixelBufferReleasePlanarBytesCallback:
/// void (*)(void *, const void *, size_t, size_t, const void **)
void FrameRefWrapper_ReleaseCallback(void *refCon, const void *dataPtr,
                                     size_t dataSize, size_t numberOfPlanes,
                                     const void *planeAddresses[]);

@end

NS_ASSUME_NONNULL_END
