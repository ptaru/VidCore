//
//  FFmpegDemuxer.mm
//  VidCore
//
//  Container I/O, packet demuxing, and seeking.
//  Separated from FFmpegDecoder for clean architecture.
//

// Fix for AVMediaType collision between AVFoundation and FFmpeg
#define AVMediaType FFmpegAVMediaType
#import "FFmpegBridge.h"
#undef AVMediaType

#import "FFmpegDemuxer.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>

#pragma mark - Data Structure Implementations

@implementation FFmpegDemuxerVideoInfo

- (BOOL)isHDR {
    // AVCOL_TRC_SMPTE2084 = 16 (PQ/HDR10)
    // AVCOL_TRC_ARIB_STD_B67 = 18 (HLG)
    return _colorTransfer == 16 || _colorTransfer == 18;
}

@end

@implementation FFmpegDemuxerPacket
@end

#pragma mark - Private Interface

@interface FFmpegDemuxer ()
@property(nonatomic, assign) AVFormatContext *formatContext;
@property(nonatomic, assign) AVPacket *packet;
@property(nonatomic, assign) int videoStreamIndex;
@property(nonatomic, assign) int audioStreamIndex;
@property(nonatomic, strong) FFmpegDemuxerVideoInfo *videoInfo;
@property(nonatomic, strong) NSMutableArray<FFmpegDemuxerPacket *> *queuedAudioPackets;
@end

#pragma mark - Constants

// For seeking audio queue management
static const double kAudioQueueTolerance = 0.05;      // 50ms for audio pre-buffer
static const NSUInteger kMaxQueuedAudioPackets = 500; // Prevent unbounded growth

// Error helper macro
#define DEMUXER_SET_ERROR_AND_CLOSE(errorPtr, errorCode, errorMsg) \
  do { \
    if (errorPtr) { \
      *errorPtr = [NSError errorWithDomain:@"FFmpegDemuxer" \
                                      code:errorCode \
                                  userInfo:@{NSLocalizedDescriptionKey: errorMsg}]; \
    } \
    [self close]; \
    return NO; \
  } while (0)

#pragma mark - Implementation

@implementation FFmpegDemuxer

#pragma mark - Initialization

- (nullable instancetype)initWithURL:(NSURL *)url error:(NSError **)error {
    self = [super init];
    if (self) {
        // Set log level to ERROR to avoid noisy logs
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            av_log_set_level(AV_LOG_ERROR);
        });
        
        _formatContext = NULL;
        _packet = NULL;
        _videoStreamIndex = -1;
        _audioStreamIndex = -1;
        _seekOptimizationEnabled = YES;
        _queuedAudioPackets = [NSMutableArray array];
        
        if (![self openFile:url error:error]) {
            return nil;
        }
    }
    return self;
}

- (void)dealloc {
    [self close];
}

#pragma mark - File Opening

- (BOOL)openFile:(NSURL *)url error:(NSError **)error {
    const char *filename = [[url path] UTF8String];
    
    // Open input file
    if (avformat_open_input(&_formatContext, filename, NULL, NULL) < 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"FFmpegDemuxer"
                                         code:1001
                                     userInfo:@{NSLocalizedDescriptionKey: @"Failed to open video file"}];
        }
        return NO;
    }
    
    // Retrieve stream information
    if (avformat_find_stream_info(_formatContext, NULL) < 0) {
        DEMUXER_SET_ERROR_AND_CLOSE(error, 1002, @"Failed to find stream information");
    }
    
    // Find the best video stream
    _videoStreamIndex = av_find_best_stream(_formatContext, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (_videoStreamIndex < 0) {
        DEMUXER_SET_ERROR_AND_CLOSE(error, 1003, @"No video stream found");
    }
    
    // Find audio stream (optional)
    _audioStreamIndex = av_find_best_stream(_formatContext, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
    
    // Allocate packet for demuxing
    _packet = av_packet_alloc();
    if (!_packet) {
        DEMUXER_SET_ERROR_AND_CLOSE(error, 1004, @"Failed to allocate packet");
    }
    
    // Build video info
    [self buildVideoInfo];
    
    return YES;
}

- (void)buildVideoInfo {
    AVStream *videoStream = _formatContext->streams[_videoStreamIndex];
    AVCodecParameters *codecPars = videoStream->codecpar;
    const AVCodec *codec = avcodec_find_decoder(codecPars->codec_id);
    
    _videoInfo = [[FFmpegDemuxerVideoInfo alloc] init];
    _videoInfo.width = codecPars->width;
    _videoInfo.height = codecPars->height;
    _videoInfo.codecName = codec ? [NSString stringWithUTF8String:codec->name] : @"unknown";
    
    // Color metadata (prefer codec params, fallback to stream)
    _videoInfo.colorPrimaries = codecPars->color_primaries;
    _videoInfo.colorTransfer = codecPars->color_trc;
    _videoInfo.colorSpace = codecPars->color_space;
    _videoInfo.colorRange = codecPars->color_range;
    
    // Check for Dolby Vision
    const AVPacketSideData *doviSideData = av_packet_side_data_get(
        codecPars->coded_side_data,
        codecPars->nb_coded_side_data, AV_PKT_DATA_DOVI_CONF);
    if (doviSideData && doviSideData->size >= sizeof(AVDOVIDecoderConfigurationRecord)) {
        _videoInfo.isDolbyVision = YES;
        const AVDOVIDecoderConfigurationRecord *doviConf = 
            (const AVDOVIDecoderConfigurationRecord *)doviSideData->data;
        _videoInfo.doviProfile = doviConf->dv_profile;
    }
    
    // Content Light Level
    const AVPacketSideData *cllSideData = av_packet_side_data_get(
        codecPars->coded_side_data,
        codecPars->nb_coded_side_data,
        AV_PKT_DATA_CONTENT_LIGHT_LEVEL);
    if (cllSideData && cllSideData->size >= sizeof(AVContentLightMetadata)) {
        const AVContentLightMetadata *cll = (const AVContentLightMetadata *)cllSideData->data;
        _videoInfo.maxContentLightLevel = cll->MaxCLL;
        _videoInfo.maxFrameAverageLightLevel = cll->MaxFALL;
    }
    
    // Mastering Display Metadata
    const AVPacketSideData *mdSideData = av_packet_side_data_get(
        codecPars->coded_side_data,
        codecPars->nb_coded_side_data,
        AV_PKT_DATA_MASTERING_DISPLAY_METADATA);
    if (mdSideData && mdSideData->size >= sizeof(AVMasteringDisplayMetadata)) {
        const AVMasteringDisplayMetadata *md = (const AVMasteringDisplayMetadata *)mdSideData->data;
        if (md->has_luminance) {
            _videoInfo.masteringDisplayMaxLuminance = (double)av_q2d(md->max_luminance);
            _videoInfo.masteringDisplayMinLuminance = (double)av_q2d(md->min_luminance);
        }
    }
    
    // Bits per component
    const AVPixFmtDescriptor *pixFmtDesc = av_pix_fmt_desc_get((enum AVPixelFormat)codecPars->format);
    _videoInfo.bitsPerComponent = pixFmtDesc ? pixFmtDesc->comp[0].depth : 8;
    
    // Frame rate
    AVRational frameRate = av_guess_frame_rate(_formatContext, videoStream, NULL);
    if (frameRate.num && frameRate.den) {
        _videoInfo.frameRate = (double)frameRate.num / (double)frameRate.den;
    } else {
        _videoInfo.frameRate = 30.0;
    }
    
    // Duration
    if (videoStream->duration != AV_NOPTS_VALUE) {
        _videoInfo.duration = (double)videoStream->duration * av_q2d(videoStream->time_base);
    } else if (_formatContext->duration != AV_NOPTS_VALUE) {
        _videoInfo.duration = (double)_formatContext->duration / AV_TIME_BASE;
    }
    
    // Audio info
    if (_audioStreamIndex >= 0) {
        AVStream *audioStream = _formatContext->streams[_audioStreamIndex];
        const AVCodec *audioCodec = avcodec_find_decoder(audioStream->codecpar->codec_id);
        if (audioCodec) {
            _videoInfo.audioCodecName = [NSString stringWithUTF8String:audioCodec->name];
        }
        _videoInfo.audioSampleRate = audioStream->codecpar->sample_rate;
        _videoInfo.audioChannels = audioStream->codecpar->ch_layout.nb_channels;
    }
}

#pragma mark - Metadata

- (nullable FFmpegDemuxerVideoInfo *)getVideoInfo {
    return _videoInfo;
}

- (BOOL)supportsHardwareDecode {
    if (!_formatContext || _videoStreamIndex < 0) return NO;
    AVCodecParameters *codecPars = _formatContext->streams[_videoStreamIndex]->codecpar;
    return codecPars->codec_id == AV_CODEC_ID_HEVC || codecPars->codec_id == AV_CODEC_ID_H264;
}

- (int)videoCodecId {
    if (!_formatContext || _videoStreamIndex < 0) return 0;
    return _formatContext->streams[_videoStreamIndex]->codecpar->codec_id;
}

- (int32_t)timeBaseNum {
    if (!_formatContext || _videoStreamIndex < 0) return 1;
    return _formatContext->streams[_videoStreamIndex]->time_base.num;
}

- (int32_t)timeBaseDen {
    if (!_formatContext || _videoStreamIndex < 0) return 1;
    return _formatContext->streams[_videoStreamIndex]->time_base.den;
}

- (nullable NSDictionary<NSString *, id> *)getVTDecoderConfig {
    if (!_formatContext || _videoStreamIndex < 0) {
        return nil;
    }
    
    AVStream *videoStream = _formatContext->streams[_videoStreamIndex];
    AVCodecParameters *codecPars = videoStream->codecpar;
    
    // Only support H264 and HEVC
    NSNumber *codecType = nil;
    if (codecPars->codec_id == AV_CODEC_ID_HEVC) {
        codecType = @(0); // 0 = hevc
    } else if (codecPars->codec_id == AV_CODEC_ID_H264) {
        codecType = @(1); // 1 = h264
    } else {
        return nil; // Unsupported codec
    }
    
    // Must have extradata
    if (!codecPars->extradata || codecPars->extradata_size == 0) {
        return nil;
    }
    
    NSData *extradata = [NSData dataWithBytes:codecPars->extradata 
                                       length:codecPars->extradata_size];
    
    // Dolby Vision config
    NSData *dolbyVisionConfig = nil;
    const AVPacketSideData *doviSideData = av_packet_side_data_get(
        codecPars->coded_side_data,
        codecPars->nb_coded_side_data, AV_PKT_DATA_DOVI_CONF);
    if (doviSideData && doviSideData->size > 0) {
        dolbyVisionConfig = [NSData dataWithBytes:doviSideData->data 
                                           length:doviSideData->size];
    }
    
    NSMutableDictionary *config = [NSMutableDictionary dictionary];
    config[@"codec"] = codecType;
    config[@"width"] = @(codecPars->width);
    config[@"height"] = @(codecPars->height);
    config[@"extradata"] = extradata;
    config[@"timeBaseNum"] = @(videoStream->time_base.num);
    config[@"timeBaseDen"] = @(videoStream->time_base.den);
    config[@"colorPrimaries"] = @(codecPars->color_primaries);
    config[@"colorTransfer"] = @(codecPars->color_trc);
    config[@"colorSpace"] = @(codecPars->color_space);
    
    if (dolbyVisionConfig) {
        config[@"dolbyVisionConfig"] = dolbyVisionConfig;
    }
    
    return config;
}

- (nullable NSDictionary<NSString *, id> *)getDecoderConfig {
    if (!_formatContext || _videoStreamIndex < 0) {
        return nil;
    }
    
    AVStream *videoStream = _formatContext->streams[_videoStreamIndex];
    AVCodecParameters *codecPars = videoStream->codecpar;
    
    NSMutableDictionary *config = [NSMutableDictionary dictionary];
    
    // Video codec info
    config[@"videoCodecId"] = @(codecPars->codec_id);
    config[@"width"] = @(codecPars->width);
    config[@"height"] = @(codecPars->height);
    config[@"pixelFormat"] = @(codecPars->format);
    config[@"videoTimeBaseNum"] = @(videoStream->time_base.num);
    config[@"videoTimeBaseDen"] = @(videoStream->time_base.den);
    
    // Video extradata
    if (codecPars->extradata && codecPars->extradata_size > 0) {
        config[@"videoExtradata"] = [NSData dataWithBytes:codecPars->extradata 
                                                   length:codecPars->extradata_size];
    }
    
    // Color metadata
    config[@"colorPrimaries"] = @(codecPars->color_primaries);
    config[@"colorTransfer"] = @(codecPars->color_trc);
    config[@"colorSpace"] = @(codecPars->color_space);
    config[@"colorRange"] = @(codecPars->color_range);
    
    // Dolby Vision config
    const AVPacketSideData *doviSideData = av_packet_side_data_get(
        codecPars->coded_side_data,
        codecPars->nb_coded_side_data, AV_PKT_DATA_DOVI_CONF);
    if (doviSideData && doviSideData->size > 0) {
        config[@"dolbyVisionConfig"] = [NSData dataWithBytes:doviSideData->data 
                                                      length:doviSideData->size];
        config[@"isDolbyVision"] = @YES;
        if (doviSideData->size >= sizeof(AVDOVIDecoderConfigurationRecord)) {
            const AVDOVIDecoderConfigurationRecord *doviConf = 
                (const AVDOVIDecoderConfigurationRecord *)doviSideData->data;
            config[@"doviProfile"] = @(doviConf->dv_profile);
        }
    }
    
    // Audio codec info (if present)
    if (_audioStreamIndex >= 0) {
        AVStream *audioStream = _formatContext->streams[_audioStreamIndex];
        AVCodecParameters *audioPars = audioStream->codecpar;
        
        config[@"audioCodecId"] = @(audioPars->codec_id);
        config[@"audioSampleRate"] = @(audioPars->sample_rate);
        config[@"audioChannels"] = @(audioPars->ch_layout.nb_channels);
        config[@"audioTimeBaseNum"] = @(audioStream->time_base.num);
        config[@"audioTimeBaseDen"] = @(audioStream->time_base.den);
        
        if (audioPars->extradata && audioPars->extradata_size > 0) {
            config[@"audioExtradata"] = [NSData dataWithBytes:audioPars->extradata 
                                                       length:audioPars->extradata_size];
        }
    }
    
    // Frame rate
    AVRational frameRate = av_guess_frame_rate(_formatContext, videoStream, NULL);
    if (frameRate.num && frameRate.den) {
        config[@"frameRate"] = @((double)frameRate.num / (double)frameRate.den);
    }
    
    // Duration
    if (videoStream->duration != AV_NOPTS_VALUE) {
        config[@"duration"] = @((double)videoStream->duration * av_q2d(videoStream->time_base));
    } else if (_formatContext->duration != AV_NOPTS_VALUE) {
        config[@"duration"] = @((double)_formatContext->duration / AV_TIME_BASE);
    }
    
    return config;
}

#pragma mark - Demuxing

- (nullable FFmpegDemuxerPacket *)demuxNextPacket {
    if (!_formatContext) {
        return nil;
    }
    
    while (av_read_frame(_formatContext, _packet) >= 0) {
        BOOL isVideo = (_packet->stream_index == _videoStreamIndex);
        BOOL isAudio = (_packet->stream_index == _audioStreamIndex && _audioStreamIndex >= 0);
        
        if (isVideo || isAudio) {
            FFmpegDemuxerPacket *packet = [self createPacketFromAV:_packet isVideo:isVideo isAudio:isAudio];
            av_packet_unref(_packet);
            return packet;
        }
        
        av_packet_unref(_packet);
    }
    
    return nil; // EOF
}

- (nullable FFmpegDemuxerPacket *)popQueuedAudioPacket {
    if (_queuedAudioPackets.count == 0) {
        return nil;
    }
    FFmpegDemuxerPacket *packet = _queuedAudioPackets.firstObject;
    [_queuedAudioPackets removeObjectAtIndex:0];
    return packet;
}

- (void)clearAudioQueue {
    [_queuedAudioPackets removeAllObjects];
}

#pragma mark - Seeking

- (BOOL)seekToKeyframe:(double)seconds {
    if (!_formatContext || _videoStreamIndex < 0) {
        return NO;
    }
    
    [_queuedAudioPackets removeAllObjects];
    
    AVStream *stream = _formatContext->streams[_videoStreamIndex];
    int64_t timestamp = (int64_t)(seconds / av_q2d(stream->time_base));
    
    if (avformat_seek_file(_formatContext, _videoStreamIndex, INT64_MIN,
                           timestamp, timestamp, AVSEEK_FLAG_BACKWARD) < 0) {
        return NO;
    }
    
    return YES;
}

- (nullable NSArray<FFmpegDemuxerPacket *> *)collectPacketsUntil:(double)targetPTS {
    if (!_formatContext || _videoStreamIndex < 0) {
        return nil;
    }
    
    AVStream *stream = _formatContext->streams[_videoStreamIndex];
    NSMutableArray<FFmpegDemuxerPacket *> *videoPackets = [NSMutableArray array];
    
    while (true) {
        int readResult = av_read_frame(_formatContext, _packet);
        if (readResult < 0) {
            break; // EOF or error
        }
        
        // Audio - queue for later
        if (_packet->stream_index == _audioStreamIndex && _audioStreamIndex >= 0) {
            AVStream *audioStream = _formatContext->streams[_audioStreamIndex];
            double audioPTS = (double)_packet->pts * av_q2d(audioStream->time_base);
            
            if (audioPTS >= targetPTS - kAudioQueueTolerance && 
                _queuedAudioPackets.count < kMaxQueuedAudioPackets) {
                FFmpegDemuxerPacket *pkt = [self createPacketFromAV:_packet isVideo:NO isAudio:YES];
                [_queuedAudioPackets addObject:pkt];
            }
            av_packet_unref(_packet);
            continue;
        }
        
        // Video - collect
        if (_packet->stream_index == _videoStreamIndex) {
            double packetPTS = (double)_packet->pts * av_q2d(stream->time_base);
            
            FFmpegDemuxerPacket *pkt = [self createPacketFromAV:_packet isVideo:YES isAudio:NO];
            [videoPackets addObject:pkt];
            av_packet_unref(_packet);
            
            if (packetPTS >= targetPTS) {
                break;
            }
            continue;
        }
        
        av_packet_unref(_packet);
    }
    
    return videoPackets.count > 0 ? videoPackets : nil;
}

- (nullable NSArray<FFmpegDemuxerPacket *> *)collectKeyframePackets {
    if (!_formatContext || _videoStreamIndex < 0) {
        return nil;
    }
    
    NSMutableArray<FFmpegDemuxerPacket *> *packets = [NSMutableArray array];
    
    while (av_read_frame(_formatContext, _packet) >= 0) {
        if (_packet->stream_index == _videoStreamIndex) {
            FFmpegDemuxerPacket *pkt = [self createPacketFromAV:_packet isVideo:YES isAudio:NO];
            [packets addObject:pkt];
            av_packet_unref(_packet);
            break; // Just the first video packet (keyframe after seek)
        }
        av_packet_unref(_packet);
    }
    
    return packets.count > 0 ? packets : nil;
}

#pragma mark - Utilities

- (nullable NSData *)extractCoverImage {
    if (!_formatContext) {
        return nil;
    }
    
    for (unsigned int i = 0; i < _formatContext->nb_streams; i++) {
        AVStream *stream = _formatContext->streams[i];
        enum AVCodecID codecId = stream->codecpar->codec_id;
        
        // Attachment streams (MP4, M4A)
        if (stream->codecpar->codec_type == AVMEDIA_TYPE_ATTACHMENT) {
            if (codecId != AV_CODEC_ID_MJPEG && codecId != AV_CODEC_ID_PNG &&
                codecId != AV_CODEC_ID_BMP) {
                continue;
            }
            if (stream->codecpar->extradata && stream->codecpar->extradata_size > 0) {
                return [NSData dataWithBytes:stream->codecpar->extradata
                                      length:stream->codecpar->extradata_size];
            }
        }
        
        // Attached pic streams (MKV)
        if (stream->codecpar->codec_type == AVMEDIA_TYPE_VIDEO &&
            (stream->disposition & AV_DISPOSITION_ATTACHED_PIC)) {
            if (codecId != AV_CODEC_ID_MJPEG && codecId != AV_CODEC_ID_PNG &&
                codecId != AV_CODEC_ID_BMP && codecId != AV_CODEC_ID_WEBP) {
                continue;
            }
            if (stream->attached_pic.data && stream->attached_pic.size > 0) {
                return [NSData dataWithBytes:stream->attached_pic.data
                                      length:stream->attached_pic.size];
            }
        }
    }
    
    return nil;
}

- (void)close {
    if (!_formatContext) {
        return;
    }
    
    NSLog(@"[FFmpegDemuxer] Closing demuxer");
    
    if (_packet) {
        av_packet_free(&_packet);
        _packet = NULL;
    }
    
    if (_formatContext) {
        avformat_close_input(&_formatContext);
        _formatContext = NULL;
    }
    
    [_queuedAudioPackets removeAllObjects];
    _videoStreamIndex = -1;
    _audioStreamIndex = -1;
}

#pragma mark - Private Helpers

- (FFmpegDemuxerPacket *)createPacketFromAV:(AVPacket *)pkt 
                                    isVideo:(BOOL)isVideo 
                                    isAudio:(BOOL)isAudio {
    FFmpegDemuxerPacket *packet = [[FFmpegDemuxerPacket alloc] init];
    packet.pts = pkt->pts;
    packet.dts = pkt->dts;
    packet.duration = pkt->duration;
    packet.isVideo = isVideo;
    packet.isAudio = isAudio;
    packet.isKeyframe = (pkt->flags & AV_PKT_FLAG_KEY) != 0;
    
    if (pkt->data && pkt->size > 0) {
        packet.data = [NSData dataWithBytes:pkt->data length:pkt->size];
        packet.size = pkt->size;
    } else {
        packet.data = [NSData data];
        packet.size = 0;
    }
    
    return packet;
}

@end
