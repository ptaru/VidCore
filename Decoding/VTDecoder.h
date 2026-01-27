//
//  VTDecoder.h
//  VidCore
//
//  [description goes here]
//

#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import "FFmpegBridge.h"

NS_ASSUME_NONNULL_BEGIN

extern NSString * const VTDecoderErrorDomain;

typedef NS_ENUM(NSInteger, VTDecoderError) {
    VTDecoderErrorUnknown = 0,
    VTDecoderErrorNoExtradata = 1,
    VTDecoderErrorFormatDescriptionCreationFailed = 2,
    VTDecoderErrorSessionCreationFailed = 3,
    VTDecoderErrorSessionNotActive = 4,
    VTDecoderErrorBlockBufferCreationFailed = 5,
    VTDecoderErrorSampleBufferCreationFailed = 6,
    VTDecoderErrorDecodeFailed = 7,
    VTDecoderErrorUnsupportedDolbyVisionProfile = 8,
};

/// Manages a global VTDecompressionSession for decoding video frames directly.
@interface VTDecoder : NSObject

/// Validates if the codec parameters are supported by this decoder (currently HEVC only).
+ (BOOL)isCodecSupported:(enum AVCodecID)codecId;

/// Initialize with FFmpeg codec parameters, stream timebase, and optional Dolby Vision configuration.
/// @param codecPars FFmpeg codec parameters containing extradata
/// @param timeBase Stream time base for PTS conversion
/// @param doviConfigData Raw dvcC/dvvC atom bytes from AV_PKT_DATA_DOVI_CONF side data, or nil for non-DoVi content
/// @param error Output error if initialization fails
- (instancetype)initWithCodecParameters:(AVCodecParameters *)codecPars
                               timeBase:(AVRational)timeBase
                    dolbyVisionSideData:(nullable NSData *)doviConfigData
                                  error:(NSError **)error;

/// Whether this decoder is handling Dolby Vision content.
@property (nonatomic, readonly) BOOL isDolbyVision;
/// Dolby Vision profile (4, 5, 7, 8) or 0 if not Dolby Vision.
@property (nonatomic, readonly) uint8_t dolbyVisionProfile;

/// Decodes an FFmpeg packet synchronously and returns the resulting CVPixelBuffer.
/// @note usage of this prevents pipelining.
- (CVPixelBufferRef _Nullable)decodePacket:(AVPacket *)packet error:(NSError **)error;

/// Sends a packet to the decoder for asynchronous decoding.
/// Call popFrame to retrieve results.
- (BOOL)sendPacket:(AVPacket *)packet error:(NSError **)error;

/// Retrieves the next available decoded frame from the internal queue.
/// @param ptsOut Output parameter for the frame's presentation timestamp.
/// Returns NULL if no frame is currently available.
- (CVPixelBufferRef _Nullable)popFrame:(CMTime *)ptsOut;

/// Average decode duration in seconds (for debugging).
@property (nonatomic, readonly) NSTimeInterval averageDecodeDuration;

/// Flushes the decompression session.
- (void)flush;

@end

NS_ASSUME_NONNULL_END
