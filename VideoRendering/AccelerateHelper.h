//
//  AccelerateHelper.h
//  VidCore
//
//  Helper class to isolate Accelerate framework usage from FFmpeg conflicts.
//

#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface AccelerateHelper : NSObject

/// Copies YUV420P planar data to a CVPixelBuffer using vImage.
/// @param srcY Source Y plane data
/// @param srcU Source U plane data
/// @param srcV Source V plane data
/// @param srcLinesize Array of 3 integers for Y, U, V strides
/// @param pixelBuffer Destination CVPixelBuffer (must be
/// kCVPixelFormatType_420YpCbCr8Planar)
/// @param width Width of the image
/// @param height Height of the image
+ (void)copyYUV420PToBuffer:(CVPixelBufferRef)pixelBuffer
                       srcY:(const uint8_t *)srcY
                       srcU:(const uint8_t *)srcU
                       srcV:(const uint8_t *)srcV
                srcLinesize:(const int *)srcLinesize
                      width:(int)width
                     height:(int)height;

+ (void)copyYUV420P10LEToBuffer:(CVPixelBufferRef)pixelBuffer
                           srcY:(const uint16_t *)srcY
                           srcU:(const uint16_t *)srcU
                           srcV:(const uint16_t *)srcV
                    srcLinesize:(const int *)srcLinesize
                          width:(int)width
                         height:(int)height;
@end

NS_ASSUME_NONNULL_END
