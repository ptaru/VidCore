//
//  FFmpegDecoder.h
//  VidCore
//
//  Objective-C++ wrapper for FFmpeg video decoding
//

#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

@class AVAudioPCMBuffer;

NS_ASSUME_NONNULL_BEGIN

/// Metadata about a video stream.
@interface FFmpegVideoInfo : NSObject
/// Video width in pixels.
@property(nonatomic, assign) int width;
/// Video height in pixels.
@property(nonatomic, assign) int height;
/// Frame rate in frames per second.
@property(nonatomic, assign) double frameRate;
/// Duration in seconds.
@property(nonatomic, assign) double duration;
/// Name of the video codec.
@property(nonatomic, copy) NSString *codecName;
/// Whether the stream uses hardware acceleration.
@property(nonatomic, assign) BOOL isHardwareAccelerated;
/// Name of the specific decoder used (e.g. "videotoolbox", "h264").
@property(nonatomic, copy) NSString *decoderName;
/// Description of the decoder implementation.
@property(nonatomic, copy) NSString *decoderDescription;
/// Color primaries (AVCOL_PRI_*: 1=BT.709, 9=BT.2020).
@property(nonatomic, assign) int colorPrimaries;
/// Transfer characteristics (AVCOL_TRC_*: 1=BT.709, 16=PQ/SMPTE2084, 18=HLG).
@property(nonatomic, assign) int colorTransfer;
/// Color space/matrix (AVCOL_SPC_*: 1=BT.709, 9=BT.2020nc).
@property(nonatomic, assign) int colorSpace;
/// Color range (AVCOL_RANGE_*: 1=video/limited, 2=full).
@property(nonatomic, assign) int colorRange;
/// Bits per color component (8, 10, 12).
@property(nonatomic, assign) int bitsPerComponent;
/// Whether the content is HDR (PQ or HLG transfer function).
@property(nonatomic, readonly) BOOL isHDR;
/// Maximum Content Light Level in cd/m² (MaxCLL), 0 if not present in metadata.
@property(nonatomic, assign) unsigned int maxContentLightLevel;
/// Maximum Frame-Average Light Level in cd/m² (MaxFALL), 0 if not present.
@property(nonatomic, assign) unsigned int maxFrameAverageLightLevel;
/// Mastering display maximum luminance in cd/m², 0 if not present.
@property(nonatomic, assign) float masteringDisplayMaxLuminance;
/// Mastering display minimum luminance in cd/m², 0 if not present.
@property(nonatomic, assign) float masteringDisplayMinLuminance;
/// Whether the content is Dolby Vision.
@property(nonatomic, assign) BOOL isDolbyVision;
/// Dolby Vision Profile ID (e.g., 5, 7, 8), 0 if not present.
@property(nonatomic, assign) int doviProfile;
/// Audio codec name (e.g., "aac", "opus"), nil if no audio stream.
@property(nonatomic, copy, nullable) NSString *audioCodecName;
/// Audio sample rate in Hz (e.g., 48000), 0 if no audio.
@property(nonatomic, assign) int audioSampleRate;
/// Number of audio channels (e.g., 2 for stereo), 0 if no audio.
@property(nonatomic, assign) int audioChannels;
@end

/// Type of decoded frame.
typedef NS_ENUM(NSInteger, FFmpegFrameType) {
  /// Video frame with pixel buffer.
  FFmpegFrameTypeVideo,
  /// Audio frame with PCM buffer.
  FFmpegFrameTypeAudio
};

/// Base class for decoded frames.
@interface FFmpegFrame : NSObject
/// The type of data in this frame.
@property(nonatomic, assign) FFmpegFrameType type;
/// Presentation timestamp in seconds.
@property(nonatomic, assign) double presentationTime;
@end

/// A decoded video frame.
@interface FFmpegVideoFrame : FFmpegFrame
/// The decoded pixel buffer (CVImageBuffer).
@property(nonatomic, assign) CVPixelBufferRef pixelBuffer;
/// Dolby Vision Profile ID (e.g., 5, 8), 0 if not present.
@property(nonatomic, assign) int doviProfile;
@end

/// A decoded audio frame.
@interface FFmpegAudioFrame : FFmpegFrame
/// The decoded audio PCM buffer.
@property(nonatomic, strong) AVAudioPCMBuffer *pcmBuffer;
@end

/// Packet data wrapper for Swift interop (avoids exposing AVPacket)
@interface FFmpegPacketData : NSObject
@property(nonatomic, assign) int32_t streamIndex;
@property(nonatomic, strong) NSData *data;
@property(nonatomic, assign) int32_t size;
@property(nonatomic, assign) int64_t pts;
@property(nonatomic, assign) int64_t dts;
@property(nonatomic, assign) int64_t duration;
@property(nonatomic, assign) int32_t flags;
@property(nonatomic, assign) BOOL isVideo;
@property(nonatomic, assign) BOOL isAudio;
@property(nonatomic, strong, nullable) NSData *ambientLightMetadata;
@end

/// Core FFmpeg wrapper for decoding video files.
///
/// This class handles the low-level interaction with FFmpeg libraries.
@interface FFmpegDecoder : NSObject

/// Initialize the decoder with a video file URL.
/// @param url The file URL to the video.
/// @param error Output error if initialization fails.


/// Initialize the decoder with a configuration dictionary from the demuxer.
/// @param config The configuration dictionary containing codec parameters.
/// @param error Output error if initialization fails.
- (nullable instancetype)initWithDemuxerConfig:(NSDictionary<NSString *, id> *)config
                                         error:(NSError **)error;

/// Get metadata about the video stream.
- (nullable FFmpegVideoInfo *)getVideoInfo;



/// Decode a packet into frames.
///
/// @param packetData The packet to decode.
- (nullable FFmpegFrame *)decodePacket:(FFmpegPacketData *)packetData;

/// Decode a video packet and return ALL available frames.
///
/// With multi-threaded decoding, a single packet may produce multiple frames.
/// @param packetData The video packet to decode.
- (nullable NSArray<FFmpegVideoFrame *> *)decodeVideoPacketWithAllFrames:
    (FFmpegPacketData *)packetData;

/// Flush the decoder to signal end of stream.
///
/// Must be called before draining remaining frames.
- (void)flushVideoDecoder;

/// Drain remaining buffered frames from the decoder.
///
/// Call this repeatedly after flushing until it returns nil.
- (nullable FFmpegVideoFrame *)drainVideoFrame;

/// Flush the codec internal buffers (video and audio).
///
/// Use this when seeking to reset the decoder state.
- (void)flushCodecBuffers;

/// Switch to a different audio stream with new codec parameters.
/// This reinitializes the audio codec context and resampler for the new format.
/// Must be called when switching between audio tracks with different codecs (e.g., AAC to EAC3).
/// @param config Configuration dictionary with new audio codec parameters.
/// @return YES if successful, NO on error.
- (BOOL)switchAudioStream:(NSDictionary<NSString *, id> *)config;

/// Release all FFmpeg resources.
- (void)close;



@end

NS_ASSUME_NONNULL_END
