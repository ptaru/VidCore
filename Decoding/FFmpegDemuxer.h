//
//  FFmpegDemuxer.h
//  VidCore
//
//  Container I/O, packet demuxing, and seeking.
//  Separated from FFmpegDecoder to enable clean decoder architecture.
//

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Data Structures

/// Video stream metadata extracted from container.
@interface FFmpegDemuxerVideoInfo : NSObject
@property(nonatomic, assign) int32_t width;
@property(nonatomic, assign) int32_t height;
@property(nonatomic, assign) double frameRate;
@property(nonatomic, assign) double duration;
@property(nonatomic, copy) NSString *codecName;
@property(nonatomic, assign) int colorPrimaries;
@property(nonatomic, assign) int colorTransfer;
@property(nonatomic, assign) int colorSpace;
@property(nonatomic, assign) int colorRange;
@property(nonatomic, assign) int bitsPerComponent;
@property(nonatomic, assign) BOOL isHDR;
@property(nonatomic, assign) BOOL isDolbyVision;
@property(nonatomic, assign) uint8_t doviProfile;
@property(nonatomic, assign) uint16_t maxContentLightLevel;
@property(nonatomic, assign) uint16_t maxFrameAverageLightLevel;
@property(nonatomic, assign) double masteringDisplayMaxLuminance;
@property(nonatomic, assign) double masteringDisplayMinLuminance;
// Audio info
@property(nonatomic, copy, nullable) NSString *audioCodecName;
@property(nonatomic, assign) int audioSampleRate;
@property(nonatomic, assign) int audioChannels;
@end

/// Packet data for decoder consumption.
@interface FFmpegDemuxerPacket : NSObject
@property(nonatomic, strong) NSData *data;
@property(nonatomic, assign) int64_t size;
@property(nonatomic, assign) int64_t pts;
@property(nonatomic, assign) int64_t dts;
@property(nonatomic, assign) int64_t duration;
@property(nonatomic, assign) BOOL isVideo;
@property(nonatomic, assign) BOOL isAudio;
@property(nonatomic, assign) BOOL isKeyframe;
@end

#pragma mark - FFmpegDemuxer

/// Container demuxer using FFmpeg's libavformat.
///
/// Handles:
/// - Opening video containers (MKV, MP4, MOV, etc.)
/// - Demuxing packets from video/audio streams
/// - Seeking to keyframes
/// - Extracting container metadata
/// - Audio packet queue management during seeks
///
/// Does NOT handle decoding - that's FFmpegDecoder's job.
@interface FFmpegDemuxer : NSObject

#pragma mark - Initialization

/// Initialize demuxer with a video file URL.
/// @param url The local file URL to open.
/// @param error On failure, contains error details.
/// @return Initialized demuxer, or nil on failure.
- (nullable instancetype)initWithURL:(NSURL *)url error:(NSError **)error;

#pragma mark - Metadata

/// Get video stream information.
- (nullable FFmpegDemuxerVideoInfo *)getVideoInfo;

/// Get VTDecoder configuration for Swift VTDecoder initialization.
/// Returns codec parameters as Swift-compatible dictionary.
- (nullable NSDictionary<NSString *, id> *)getVTDecoderConfig;

/// Get full decoder configuration for FFmpegDecoder decode-only mode.
/// Contains all parameters needed to initialize FFmpegDecoder without a URL.
/// Keys: codecId, width, height, extradata, timeBaseNum, timeBaseDen,
///       audioCodecId, audioExtradata, audioSampleRate, audioChannels, etc.
- (nullable NSDictionary<NSString *, id> *)getDecoderConfig;

/// Whether the video stream uses supported hardware codec (HEVC/H264).
@property(nonatomic, readonly) BOOL supportsHardwareDecode;

/// Codec ID for the video stream.
@property(nonatomic, readonly) int videoCodecId;

/// Video stream time base numerator.
@property(nonatomic, readonly) int32_t timeBaseNum;

/// Video stream time base denominator.
@property(nonatomic, readonly) int32_t timeBaseDen;

#pragma mark - Demuxing

/// Demux the next packet from the container.
/// @return The next video or audio packet, or nil at EOF/error.
- (nullable FFmpegDemuxerPacket *)demuxNextPacket;

/// Pop the next queued audio packet (from seek operations).
/// Audio packets near seek target are queued for later playback.
/// @return Queued audio packet, or nil if queue is empty.
- (nullable FFmpegDemuxerPacket *)popQueuedAudioPacket;

/// Clear any queued audio packets.
- (void)clearAudioQueue;

#pragma mark - Seeking

/// Seek to the nearest keyframe before the target time.
/// This only positions the demuxer - decoding must be done separately.
/// @param seconds Target time in seconds.
/// @return YES if seek succeeded.
- (BOOL)seekToKeyframe:(double)seconds;

/// Collect video packets from current position until target PTS.
/// Used for frame-accurate seeking (collect keyframe through target).
/// Also queues relevant audio packets.
/// @param targetPTS Target presentation time in seconds.
/// @return Array of video packets to decode, or nil on error.
- (nullable NSArray<FFmpegDemuxerPacket *> *)collectPacketsUntil:(double)targetPTS;

/// Collect video packets for inaccurate seek (keyframe only).
/// @return Array containing just the keyframe packet(s).
- (nullable NSArray<FFmpegDemuxerPacket *> *)collectKeyframePackets;

#pragma mark - Utilities

/// Extract embedded cover image from container.
/// @return Cover image data (JPEG/PNG), or nil if not found.
- (nullable NSData *)extractCoverImage;

/// Release all demuxer resources.
- (void)close;

/// Whether seek optimization (skip non-ref frames) is enabled.
@property(nonatomic, assign) BOOL seekOptimizationEnabled;

@end

NS_ASSUME_NONNULL_END
