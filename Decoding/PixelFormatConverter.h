//
//  PixelFormatConverter.h
//  VidCore
//
//  Converts FFmpeg AVFrame pixel formats to CVPixelBuffer for Metal rendering
//

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

// Forward declaration to avoid exposing FFmpeg types in header
struct AVFrame;
struct SwsContext;

NS_ASSUME_NONNULL_BEGIN

/// Converts FFmpeg decoded frames to CVPixelBuffer for GPU rendering.
/// Handles YUV420P (8-bit), YUV420P10LE (10-bit HDR), and fallback formats.
@interface PixelFormatConverter : NSObject

/// Initialize the converter.
- (instancetype)init;

/// Convert an FFmpeg frame to a CVPixelBuffer.
/// @param frame The decoded AVFrame in YUV format
/// @return A retained CVPixelBuffer ready for Metal rendering, or NULL on failure
- (nullable CVPixelBufferRef)convertFrame:(struct AVFrame *)frame;

/// Release all resources (pools, sws context).
- (void)cleanup;

@end

NS_ASSUME_NONNULL_END
