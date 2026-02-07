//
//  FFmpegDecoder.mm
//  VidCore
//
//  FFmpeg video decoder implementation with VideoToolbox hardware acceleration
//

// Fix for AVMediaType collision between AVFoundation and FFmpeg
#define AVMediaType FFmpegAVMediaType
#import "FFmpegBridge.h"
#undef AVMediaType

#import "FFmpegDecoder.h"
#import "PixelFormatConverter.h"
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreVideo/CoreVideo.h>

// Forward declaration for the hw_format callback
static enum AVPixelFormat get_hw_format(AVCodecContext *ctx,
                                        const enum AVPixelFormat *pix_fmts);

#pragma mark - FFmpegVideoInfo

@implementation FFmpegVideoInfo
// isHDR is true for PQ (SMPTE2084) or HLG transfer functions
- (BOOL)isHDR {
  // AVCOL_TRC_SMPTE2084 = 16 (PQ/HDR10)
  // AVCOL_TRC_ARIB_STD_B67 = 18 (HLG)
  return _colorTransfer == 16 || _colorTransfer == 18;
}
@end

#pragma mark - FFmpegFrame & Subclasses

@implementation FFmpegFrame
@end

@implementation FFmpegVideoFrame
- (void)dealloc {
  if (_pixelBuffer) {
    CVPixelBufferRelease(_pixelBuffer);
    _pixelBuffer = NULL;
  }
}
@end

@implementation FFmpegAudioFrame
@end

@implementation FFmpegSubtitleBitmap
@end

@implementation FFmpegSubtitleFrame
@end

#pragma mark - FFmpegPacketData

@implementation FFmpegPacketData
@end

@interface FFmpegDecoder ()

@property(nonatomic, assign)
    AVCodecContext *codecContext; // Video codec context
// SampleBufferBuilder now handled by Swift VideoDecoder
@property(nonatomic, assign)
    AVCodecContext *audioCodecContext; // Audio codec context
@property(nonatomic, assign)
    AVCodecContext *subtitleCodecContext; // Subtitle codec context

@property(nonatomic, assign) SwrContext *swrContext;
@property(nonatomic, assign) AVFrame *frame;
@property(nonatomic, assign) AVFrame *swFrame; // For hardware frame transfer
@property(nonatomic, assign) AVFrame *audioFrame;
@property(nonatomic, assign) AVFrame *swrOutputFrame; // For resampled audio
@property(nonatomic, assign) AVPacket *packet;
@property(nonatomic, assign) int videoStreamIndex;
@property(nonatomic, assign) int audioStreamIndex;
@property(nonatomic, assign) int subtitleStreamIndex;
@property(nonatomic, strong) FFmpegVideoInfo *videoInfo;
@property(nonatomic, assign) AVBufferRef *hwDeviceCtx;
@property(nonatomic, assign) BOOL usingHardwareDecoder;
@property(nonatomic, assign) enum AVPixelFormat hwPixelFormat;
// Pixel format converter for software decode path
@property(nonatomic, strong) PixelFormatConverter *pixelFormatConverter;

// Time base for decode-only mode (when formatContext is NULL)
@property(nonatomic, assign) int32_t videoTimeBaseNum;
@property(nonatomic, assign) int32_t videoTimeBaseDen;
@property(nonatomic, assign) int32_t audioTimeBaseNum;
@property(nonatomic, assign) int32_t audioTimeBaseDen;
@property(nonatomic, assign) int32_t subtitleTimeBaseNum;
@property(nonatomic, assign) int32_t subtitleTimeBaseDen;
@property(nonatomic, assign) double audioNextPTS;
@property(nonatomic, assign) int32_t swrSrcSampleRate;
@property(nonatomic, assign) int32_t swrSrcChannels;
@property(nonatomic, assign) enum AVSampleFormat swrSrcFormat;
@property(nonatomic, assign) BOOL isClosed;
@end
#pragma mark - Internal Helper Functions

static const enum AVSampleFormat kAudioSampleFormat = AV_SAMPLE_FMT_FLTP;
static const int kAudioSampleRateFallback = 48000;
static const int kAudioChannelsFallback = 2; // Stereo

// Static variable to store the expected hw pixel format for the callback
static enum AVPixelFormat s_hwPixelFormat = AV_PIX_FMT_NONE;

static UInt32
CoreAudioChannelBitmapFromFFmpegLayout(const AVChannelLayout *layout) {
  if (!layout) {
    return 0;
  }

  uint64_t mask = layout->u.mask;

  UInt32 bitmap = 0;
  if (mask & AV_CH_FRONT_LEFT)
    bitmap |= kAudioChannelBit_Left;
  if (mask & AV_CH_FRONT_RIGHT)
    bitmap |= kAudioChannelBit_Right;
  if (mask & AV_CH_FRONT_CENTER)
    bitmap |= kAudioChannelBit_Center;
  if (mask & AV_CH_LOW_FREQUENCY)
    bitmap |= kAudioChannelBit_LFEScreen;
  if (mask & AV_CH_BACK_LEFT)
    bitmap |= kAudioChannelBit_LeftSurround;
  if (mask & AV_CH_BACK_RIGHT)
    bitmap |= kAudioChannelBit_RightSurround;
  if (mask & AV_CH_FRONT_LEFT_OF_CENTER)
    bitmap |= kAudioChannelBit_LeftCenter;
  if (mask & AV_CH_FRONT_RIGHT_OF_CENTER)
    bitmap |= kAudioChannelBit_RightCenter;
  if (mask & AV_CH_BACK_CENTER)
    bitmap |= kAudioChannelBit_CenterSurround;
  if (mask & AV_CH_SIDE_LEFT)
    bitmap |= kAudioChannelBit_LeftSurroundDirect;
  if (mask & AV_CH_SIDE_RIGHT)
    bitmap |= kAudioChannelBit_RightSurroundDirect;
  if (mask & AV_CH_TOP_CENTER)
    bitmap |= kAudioChannelBit_TopCenterSurround;
  if (mask & AV_CH_TOP_FRONT_LEFT)
    bitmap |= kAudioChannelBit_VerticalHeightLeft;
  if (mask & AV_CH_TOP_FRONT_CENTER)
    bitmap |= kAudioChannelBit_VerticalHeightCenter;
  if (mask & AV_CH_TOP_FRONT_RIGHT)
    bitmap |= kAudioChannelBit_VerticalHeightRight;
  if (mask & AV_CH_TOP_BACK_LEFT)
    bitmap |= kAudioChannelBit_TopBackLeft;
  if (mask & AV_CH_TOP_BACK_CENTER)
    bitmap |= kAudioChannelBit_TopBackCenter;
  if (mask & AV_CH_TOP_BACK_RIGHT)
    bitmap |= kAudioChannelBit_TopBackRight;

  return bitmap;
}

static AVAudioChannelLayout *
CreateChannelLayoutFromFFmpeg(const AVChannelLayout *layout, int channels) {
  if (!layout || channels <= 2) {
    return nil;
  }

  UInt32 bitmap = CoreAudioChannelBitmapFromFFmpegLayout(layout);
  if (bitmap == 0) {
    return nil;
  }

  if (__builtin_popcount(bitmap) != channels) {
    return nil;
  }

  AudioChannelLayout acl = {0};
  acl.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelBitmap;
  acl.mChannelBitmap = bitmap;
  acl.mNumberChannelDescriptions = 0;

  return [[AVAudioChannelLayout alloc] initWithLayout:&acl];
}

static enum AVPixelFormat get_hw_format(AVCodecContext *ctx,
                                        const enum AVPixelFormat *pix_fmts) {
  for (const enum AVPixelFormat *p = pix_fmts; *p != AV_PIX_FMT_NONE; p++) {
    if (*p == s_hwPixelFormat) {
      return *p;
    }
  }
  // Hardware format not available, return first software format as fallback
  return pix_fmts[0];
}

#pragma mark - FFmpegDecoder Implementation

@implementation FFmpegDecoder

#pragma mark - Initialization & Lifecycle

- (nullable instancetype)initWithDemuxerConfig:
                             (NSDictionary<NSString *, id> *)config
                                         error:(NSError **)error {
  self = [super init];
  if (self) {
    // Set log level to ERROR
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
      av_log_set_level(AV_LOG_ERROR);
    });

    // Initialize state
    _codecContext = NULL;
    _audioCodecContext = NULL;
    _swrContext = NULL;
    _frame = NULL;
    _swFrame = NULL;
    _audioFrame = NULL;
    _swrOutputFrame = NULL;
    _packet = NULL;
    _videoStreamIndex = 0; // Dummy index for decode-only mode
    _audioStreamIndex = -1;
    _hwDeviceCtx = NULL;
    _usingHardwareDecoder = NO;
    _hwPixelFormat = AV_PIX_FMT_VIDEOTOOLBOX;
    _pixelFormatConverter = [[PixelFormatConverter alloc] init];
    _audioNextPTS = -1.0;

    _subtitleStreamIndex = -1;
    _subtitleCodecContext = NULL;
    _swrSrcSampleRate = 0;
    _swrSrcChannels = 0;
    _swrSrcFormat = AV_SAMPLE_FMT_NONE;
    _isClosed = NO;

    // Extract config values
    int videoCodecId = [config[@"videoCodecId"] intValue];
    int width = [config[@"width"] intValue];
    int height = [config[@"height"] intValue];
    int pixelFormat = [config[@"pixelFormat"] intValue];
    NSData *videoExtradata = config[@"videoExtradata"];

    // Find video codec
    const AVCodec *codec = avcodec_find_decoder((enum AVCodecID)videoCodecId);
    if (!codec) {
      if (error) {
        *error = [NSError
            errorWithDomain:@"FFmpegDecoder"
                       code:2001
                   userInfo:@{NSLocalizedDescriptionKey : @"Codec not found"}];
      }
      return nil;
    }

    // Allocate video codec context
    _codecContext = avcodec_alloc_context3(codec);
    if (!_codecContext) {
      if (error) {
        *error = [NSError errorWithDomain:@"FFmpegDecoder"
                                     code:2002
                                 userInfo:@{
                                   NSLocalizedDescriptionKey :
                                       @"Failed to allocate codec context"
                                 }];
      }
      return nil;
    }

    // Set codec parameters
    _codecContext->width = width;
    _codecContext->height = height;
    _codecContext->pix_fmt = (enum AVPixelFormat)pixelFormat;
    _codecContext->color_primaries =
        (enum AVColorPrimaries)[config[@"colorPrimaries"] intValue];
    _codecContext->color_trc =
        (enum AVColorTransferCharacteristic)[config[@"colorTransfer"] intValue];
    _codecContext->colorspace =
        (enum AVColorSpace)[config[@"colorSpace"] intValue];
    _codecContext->color_range =
        (enum AVColorRange)[config[@"colorRange"] intValue];

    // Set timebase
    _videoTimeBaseNum = [config[@"videoTimeBaseNum"] intValue];
    _videoTimeBaseDen = [config[@"videoTimeBaseDen"] intValue];

    if (_videoTimeBaseDen > 0) {
      AVRational tb = (AVRational){_videoTimeBaseNum, _videoTimeBaseDen};
      _codecContext->pkt_timebase = tb;
      _codecContext->time_base = tb;
    }

    // Set extradata
    if (videoExtradata && videoExtradata.length > 0) {
      _codecContext->extradata = (uint8_t *)av_malloc(
          videoExtradata.length + AV_INPUT_BUFFER_PADDING_SIZE);
      if (_codecContext->extradata) {
        memcpy(_codecContext->extradata, videoExtradata.bytes,
               videoExtradata.length);
        _codecContext->extradata_size = (int)videoExtradata.length;
      }
    }

    // Try hardware acceleration
    BOOL hwSuccess = [self initHardwareDecoder:codec error:nil];
    if (hwSuccess && _hwDeviceCtx) {
      _codecContext->hw_device_ctx = av_buffer_ref(_hwDeviceCtx);
      _codecContext->get_format = get_hw_format;
      _usingHardwareDecoder = YES;
    } else {
      // Software decode with threading
      _codecContext->thread_count = 0;
      _codecContext->thread_type = FF_THREAD_FRAME | FF_THREAD_SLICE;
    }

    // Open video codec
    if (avcodec_open2(_codecContext, codec, NULL) < 0) {
      if (error) {
        *error = [NSError
            errorWithDomain:@"FFmpegDecoder"
                       code:2003
                   userInfo:@{
                     NSLocalizedDescriptionKey : @"Failed to open codec"
                   }];
      }
      avcodec_free_context(&_codecContext);
      return nil;
    }

    // Setup audio codec if present
    if (config[@"audioCodecId"]) {
      int audioCodecId = [config[@"audioCodecId"] intValue];
      const AVCodec *audioCodec =
          avcodec_find_decoder((enum AVCodecID)audioCodecId);
      if (audioCodec) {
        _audioCodecContext = avcodec_alloc_context3(audioCodec);
        if (_audioCodecContext) {
          _audioCodecContext->sample_rate =
              [config[@"audioSampleRate"] intValue];
          av_channel_layout_default(&_audioCodecContext->ch_layout,
                                    [config[@"audioChannels"] intValue]);

          NSData *audioExtradata = config[@"audioExtradata"];
          if (audioExtradata && audioExtradata.length > 0) {
            _audioCodecContext->extradata = (uint8_t *)av_malloc(
                audioExtradata.length + AV_INPUT_BUFFER_PADDING_SIZE);
            if (_audioCodecContext->extradata) {
              memcpy(_audioCodecContext->extradata, audioExtradata.bytes,
                     audioExtradata.length);
              _audioCodecContext->extradata_size = (int)audioExtradata.length;
            }
          }

          if (avcodec_open2(_audioCodecContext, audioCodec, NULL) >= 0) {
            _audioStreamIndex = 1; // Dummy index for decode-only mode
            // Store audio time base for PTS calculation
            _audioTimeBaseNum = [config[@"audioTimeBaseNum"] intValue];
            _audioTimeBaseDen = [config[@"audioTimeBaseDen"] intValue];
          } else {
            avcodec_free_context(&_audioCodecContext);
          }
        }
      }
    }

    // Setup default subtitle codec if present
    if (config[@"subtitleCodecId"]) {
      int subtitleCodecId = [config[@"subtitleCodecId"] intValue];
      const AVCodec *subtitleCodec =
          avcodec_find_decoder((enum AVCodecID)subtitleCodecId);
      if (subtitleCodec) {
        _subtitleCodecContext = avcodec_alloc_context3(subtitleCodec);
        if (_subtitleCodecContext) {
          _subtitleTimeBaseNum = [config[@"subtitleTimeBaseNum"] intValue];
          _subtitleTimeBaseDen = [config[@"subtitleTimeBaseDen"] intValue];
          _subtitleStreamIndex = [config[@"subtitleStreamIndex"] intValue];

          NSData *subtitleExtradata = config[@"subtitleExtradata"];
          if (subtitleExtradata && subtitleExtradata.length > 0) {
            _subtitleCodecContext->extradata = (uint8_t *)av_malloc(
                subtitleExtradata.length + AV_INPUT_BUFFER_PADDING_SIZE);
            if (_subtitleCodecContext->extradata) {
              memcpy(_subtitleCodecContext->extradata, subtitleExtradata.bytes,
                     subtitleExtradata.length);
              _subtitleCodecContext->extradata_size =
                  (int)subtitleExtradata.length;
            }
          }

          if (avcodec_open2(_subtitleCodecContext, subtitleCodec, NULL) < 0) {
            avcodec_free_context(&_subtitleCodecContext);
            _subtitleCodecContext = NULL;
            _subtitleStreamIndex = -1;
          }
        }
      }
    }

    // Allocate frames
    _frame = av_frame_alloc();
    _swFrame = av_frame_alloc();
    _audioFrame = av_frame_alloc();
    _swrOutputFrame = av_frame_alloc();
    _packet = av_packet_alloc();

    if (!_frame || !_swFrame || !_packet || !_audioFrame || !_swrOutputFrame) {
      if (error) {
        *error = [NSError
            errorWithDomain:@"FFmpegDecoder"
                       code:2004
                   userInfo:@{
                     NSLocalizedDescriptionKey : @"Failed to allocate frames"
                   }];
      }
      [self close];
      return nil;
    }

    // Create video info
    _videoInfo = [[FFmpegVideoInfo alloc] init];
    _videoInfo.width = width;
    _videoInfo.height = height;
    _videoInfo.codecName = [NSString stringWithUTF8String:codec->name];
    _videoInfo.isHardwareAccelerated = _usingHardwareDecoder;
    _videoInfo.decoderName =
        _usingHardwareDecoder
            ? [NSString stringWithFormat:@"%s_videotoolbox", codec->name]
            : [NSString stringWithFormat:@"%s", codec->name];
    _videoInfo.decoderDescription =
        _usingHardwareDecoder ? @"Hardware Acceleration (VideoToolbox)"
                              : @"Software Decoding (CPU)";
    _videoInfo.colorPrimaries = [config[@"colorPrimaries"] intValue];
    _videoInfo.colorTransfer = [config[@"colorTransfer"] intValue];
    _videoInfo.colorSpace = [config[@"colorSpace"] intValue];
    _videoInfo.colorRange = [config[@"colorRange"] intValue];
    _videoInfo.isDolbyVision = [config[@"isDolbyVision"] boolValue];
    _videoInfo.doviProfile = [config[@"doviProfile"] intValue];
    _videoInfo.frameRate = [config[@"frameRate"] doubleValue] ?: 30.0;
    _videoInfo.duration = [config[@"duration"] doubleValue];

    if (config[@"audioCodecId"]) {
      const AVCodec *audioCodec = avcodec_find_decoder(
          (enum AVCodecID)[config[@"audioCodecId"] intValue]);
      if (audioCodec) {
        _videoInfo.audioCodecName =
            [NSString stringWithUTF8String:audioCodec->name];
      }
      _videoInfo.audioSampleRate = [config[@"audioSampleRate"] intValue];
      _videoInfo.audioChannels = [config[@"audioChannels"] intValue];
    }
  }
  return self;
}

- (void)dealloc {
  [self close];
}

- (BOOL)initHardwareDecoder:(const AVCodec *)codec error:(NSError **)error {
  // Create VideoToolbox hardware device context
  int ret = av_hwdevice_ctx_create(&_hwDeviceCtx, AV_HWDEVICE_TYPE_VIDEOTOOLBOX,
                                   NULL, NULL, 0);
  if (ret < 0) {

    return NO;
  }

  // Verify the codec supports VideoToolbox
  for (int i = 0;; i++) {
    const AVCodecHWConfig *config = avcodec_get_hw_config(codec, i);
    if (!config) {

      av_buffer_unref(&_hwDeviceCtx);
      _hwDeviceCtx = NULL;
      return NO;
    }
    if (config->methods & AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX &&
        config->device_type == AV_HWDEVICE_TYPE_VIDEOTOOLBOX) {
      _hwPixelFormat = config->pix_fmt;
      s_hwPixelFormat = _hwPixelFormat;

      break;
    }
  }

  return YES;
}

- (nullable FFmpegVideoInfo *)getVideoInfo {
  return _videoInfo;
}

- (nullable FFmpegFrame *)decodePacket:(FFmpegPacketData *)packetData {
  if (!packetData) {
    return nil;
  }

  // For audio, use decodeAudioPacket directly
  if (packetData.isAudio && _audioCodecContext) {
    AVPacket *pkt = [self createAVPacketFromData:packetData];
    if (!pkt)
      return nil;
    FFmpegAudioFrame *result = [self decodeAudioPacket:pkt];
    av_packet_free(&pkt);
    return result;
  }

  if (packetData.isSubtitle && _subtitleCodecContext) {
    AVPacket *pkt = [self createAVPacketFromData:packetData];
    if (!pkt)
      return nil;
    FFmpegSubtitleFrame *result = [self decodeSubtitlePacket:pkt];
    av_packet_free(&pkt);
    return result;
  }

  // For video, decode all frames but return only the first one
  // (for backward compatibility - use decodeVideoPacketWithAllFrames for full
  // output)
  if (packetData.isVideo && _codecContext) {
    NSArray<FFmpegVideoFrame *> *frames =
        [self decodeVideoPacketWithAllFrames:packetData];
    return frames.firstObject;
  }

  return nil;
}

- (nullable NSArray<FFmpegVideoFrame *> *)decodeVideoPacketWithAllFrames:
    (FFmpegPacketData *)packetData {
  if (!packetData || !packetData.isVideo || !_codecContext) {
    return nil;
  }

  AVPacket *pkt = [self createAVPacketFromData:packetData];
  if (!pkt)
    return nil;

  NSArray<FFmpegVideoFrame *> *result = [self decodeVideoPacket:pkt];
  av_packet_free(&pkt);
  return result;
}

/// Helper to create AVPacket from FFmpegPacketData
- (nullable AVPacket *)createAVPacketFromData:(FFmpegPacketData *)packetData {
  AVPacket *pkt = av_packet_alloc();
  if (!pkt) {
    return nil;
  }

  // Allocate buffer and copy data
  if (packetData.size > 0 && packetData.data.length > 0) {
    if (av_new_packet(pkt, packetData.size) < 0) {
      av_packet_free(&pkt);
      return nil;
    }
    memcpy(pkt->data, packetData.data.bytes, packetData.size);
  }

  pkt->stream_index = packetData.streamIndex;
  pkt->pts = packetData.pts;
  pkt->dts = packetData.dts;
  pkt->duration = packetData.duration;
  pkt->flags = packetData.flags;

  return pkt;
}

/// Decode a video packet and return ALL available frames
/// With multi-threaded decoding, the decoder may have multiple frames ready
- (nullable NSArray<FFmpegVideoFrame *> *)decodeVideoPacket:(AVPacket *)pkt {
  // Note: SampleBufferBuilder is now used by VideoDecoder.swift for H264/HEVC
  // passthrough This method handles FFmpeg software and FFmpeg-VideoToolbox
  // paths

  if (avcodec_send_packet(_codecContext, pkt) < 0) {
    return nil;
  }

  NSMutableArray<FFmpegVideoFrame *> *frames = [NSMutableArray array];

  // Drain ALL available frames from the decoder
  while (true) {
    int ret = avcodec_receive_frame(_codecContext, _frame);

    if (ret == AVERROR(EAGAIN)) {
      // Need more packets before output is available
      break;
    }
    if (ret == AVERROR_EOF || ret < 0) {
      // End of stream or error
      break;
    }

    int64_t finalPts = _frame->pts;
    if (finalPts == AV_NOPTS_VALUE) {
      finalPts = _frame->best_effort_timestamp;
    }

    double pts = 0.0;
    if (finalPts != AV_NOPTS_VALUE) {
      if (_videoTimeBaseDen > 0) {
        pts = (double)finalPts * (double)_videoTimeBaseNum /
              (double)_videoTimeBaseDen;
      }
    }

    FFmpegVideoFrame *videoFrame = [self createVideoFrameFromDecodedFrame:pts];
    if (!videoFrame) {
      continue; // Skip this frame but keep draining
    }

    [frames addObject:videoFrame];
  }

  return frames.count > 0 ? frames : nil;
}

- (nullable FFmpegAudioFrame *)decodeAudioPacket:(AVPacket *)pkt {
  NSArray<FFmpegAudioFrame *> *frames =
      [self decodeAudioPacketWithAllFramesAV:pkt];
  return frames.firstObject;
}

- (nullable NSArray<FFmpegAudioFrame *> *)decodeAudioPacketWithAllFrames:
    (FFmpegPacketData *)packetData {
  if (!packetData || !packetData.isAudio || !_audioCodecContext) {
    return nil;
  }

  AVPacket *pkt = [self createAVPacketFromData:packetData];
  if (!pkt)
    return nil;

  NSArray<FFmpegAudioFrame *> *frames =
      [self decodeAudioPacketWithAllFramesAV:pkt];
  av_packet_free(&pkt);
  return frames;
}

- (nullable NSArray<FFmpegAudioFrame *> *)decodeAudioPacketWithAllFramesAV:
    (AVPacket *)pkt {
  if (avcodec_send_packet(_audioCodecContext, pkt) < 0) {
    return nil;
  }

  NSMutableArray<FFmpegAudioFrame *> *frames = [NSMutableArray array];

  while (true) {
    int ret = avcodec_receive_frame(_audioCodecContext, _audioFrame);
    if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) {
      break;
    }
    if (ret < 0) {
      break;
    }

    AVAudioPCMBuffer *pcmBuffer = [self convertAudioFrame:_audioFrame];
    if (!pcmBuffer) {
      continue;
    }

    double pts = 0.0;
    bool hasPTS = false;
    int64_t ts = _audioFrame->pts;
    if (ts == AV_NOPTS_VALUE) {
      ts = _audioFrame->best_effort_timestamp;
    }
    if (ts != AV_NOPTS_VALUE && _audioTimeBaseDen > 0) {
      pts = (double)ts * (double)_audioTimeBaseNum / (double)_audioTimeBaseDen;
      hasPTS = true;
    } else if (_audioNextPTS >= 0.0) {
      pts = _audioNextPTS;
    }

    double duration = 0.0;
    if (pcmBuffer.frameLength > 0) {
      duration =
          (double)pcmBuffer.frameLength / (double)pcmBuffer.format.sampleRate;
    }

    if (_audioNextPTS >= 0.0 && hasPTS && pts < _audioNextPTS - 0.000001) {
      // Enforce monotonic audio PTS for system renderer stability.
      pts = _audioNextPTS;
    }
    _audioNextPTS = pts + duration;

    FFmpegAudioFrame *audioFrame = [[FFmpegAudioFrame alloc] init];
    audioFrame.type = FFmpegFrameTypeAudio;
    audioFrame.pcmBuffer = pcmBuffer;
    audioFrame.presentationTime = pts;

    [frames addObject:audioFrame];
  }

  return frames.count > 0 ? frames : nil;
}

- (nullable FFmpegSubtitleFrame *)decodeSubtitlePacket:(AVPacket *)pkt {
  if (!_subtitleCodecContext)
    return nil;

  int gotSubtitle = 0;
  AVSubtitle subtitle;
  int ret = avcodec_decode_subtitle2(_subtitleCodecContext, &subtitle,
                                     &gotSubtitle, pkt);

  if (ret < 0 || !gotSubtitle) {
    return nil;
  }

  FFmpegSubtitleFrame *frame = [[FFmpegSubtitleFrame alloc] init];
  frame.type = FFmpegFrameTypeSubtitle;
  double pts = 0.0;
  if (subtitle.pts != AV_NOPTS_VALUE) {
    pts = (double)subtitle.pts / AV_TIME_BASE;
  } else if (pkt->pts != AV_NOPTS_VALUE && _subtitleTimeBaseDen > 0) {
    pts = (double)pkt->pts * (double)_subtitleTimeBaseNum /
          (double)_subtitleTimeBaseDen;
  }

  double startTime = pts + (double)subtitle.start_display_time / 1000.0;
  double endTime = pts + (double)subtitle.end_display_time / 1000.0;

  // If end time is invalid (<= start time), try to deduce from packet or
  // default
  if (subtitle.end_display_time <= subtitle.start_display_time) {
    if (pkt->duration > 0 && _subtitleTimeBaseDen > 0) {
      double pktDuration = (double)pkt->duration *
                           (double)_subtitleTimeBaseNum /
                           (double)_subtitleTimeBaseDen;
      endTime = startTime + pktDuration;
    } else {
      // Fallback to a default duration (e.g. 3.0 seconds) to ensure visibility
      // or use -1 to indicate "until next" depending on player logic.
      // Given the flash issue, a reasonable default is safe.
      endTime = startTime + 3.0;
    }
  }

  frame.startTime = startTime;
  frame.endTime = endTime;

  if (subtitle.num_rects > 0) {
    // We handle all rects. Text is merged, bitmaps are collected.
    NSMutableString *fullText = [NSMutableString string];
    NSMutableArray *bitmaps = [NSMutableArray array];
    BOOL hasASS = NO;

    for (unsigned int i = 0; i < subtitle.num_rects; i++) {
      AVSubtitleRect *rect = subtitle.rects[i];

      if (rect->type == SUBTITLE_TEXT) {
        if (!hasASS && rect->text) {
          NSString *textStr = [NSString stringWithUTF8String:rect->text];
          if (textStr) {
            [fullText appendString:textStr];
          }
        }
      } else if (rect->type == SUBTITLE_ASS) {
        if (rect->ass) {
          NSString *assStr = [NSString stringWithUTF8String:rect->ass];
          if (assStr) {
            if (!hasASS) {
              [fullText setString:@""];
            }
            [fullText appendString:assStr];
          }
          frame.isASS = YES;
          hasASS = YES;
        }
      } else if (rect->type == SUBTITLE_BITMAP) {
        // Bitmap support
        int w = rect->w;
        int h = rect->h;

        if (w > 0 && h > 0) {
          // Allocate RGBA buffer (4 bytes per pixel)
          size_t dataSize = w * h * 4;
          uint8_t *rgbaData = (uint8_t *)malloc(dataSize);

          if (rgbaData) {
            uint8_t *srcData = rect->data[0];
            int srcLinesize = rect->linesize[0];
            uint32_t *palette =
                (uint32_t *)rect->data[1]; // AVPacket usually provides
                                           // palette in data[1] for bitmaps

            if (rect->nb_colors > 0 && palette) {
              // Paletted image (e.g. DVD/VobSub or PGS)
              for (int y = 0; y < h; y++) {
                for (int x = 0; x < w; x++) {
                  uint8_t colorIndex = srcData[y * srcLinesize + x];
                  // palette is likely BGRA or RGBA depending on platform,
                  // FFmpeg usually outputs in native endian or specific
                  // format FFmpeg palette is usually 0xAABBGGRR (little
                  // endian) -> R, G, B, A in byte order? Actually FFmpeg
                  // palettes are typically 32-bit AABBGGRR. Let's copy it
                  // directly for now and fix color components if needed
                  // during rendering or testing. AVPalette is uint32_t.

                  uint32_t color = palette[colorIndex];
                  // Write to output buffer
                  uint32_t *dstPixel = (uint32_t *)(rgbaData + (y * w + x) * 4);
                  *dstPixel = color;
                }
              }
            } else {
              // Non-paletted (presumably already RGBA or similar, though rare
              // for basic rects without swscale) If it's not paletted, we
              // might need more complex handling, but PGS/VobSub are usually
              // paletted. For safety, if no palette, we just zero it out or
              // copy if format known. Assuming it *might* be raw RGB if
              // encoded that way? Let's log warning and fill transparent.
              free(rgbaData);
              rgbaData = NULL;
            }

            if (rgbaData) {
              NSData *bitmapData = [NSData dataWithBytesNoCopy:rgbaData
                                                        length:dataSize
                                                  freeWhenDone:YES];

              // Raw pixel dimensions for image creation
              // Normalize coordinates
              // Prefer subtitle codec dimensions (canvas size) if available
              double refWidth = 0;
              double refHeight = 0;

              if (_subtitleCodecContext && _subtitleCodecContext->width > 0 &&
                  _subtitleCodecContext->height > 0) {
                refWidth = (double)_subtitleCodecContext->width;
                refHeight = (double)_subtitleCodecContext->height;
              } else if (_codecContext && _codecContext->width > 0 &&
                         _codecContext->height > 0) {
                // Fallback to video dimensions
                refWidth = (double)_codecContext->width;
                refHeight = (double)_codecContext->height;
              }

              double normX = 0, normY = 0, normW = 0, normH = 0;
              if (refWidth > 0 && refHeight > 0) {
                normX = (double)rect->x / refWidth;
                normY = (double)rect->y / refHeight;
                normW = (double)w / refWidth;
                normH = (double)h / refHeight;
              }

              FFmpegSubtitleBitmap *bitmap =
                  [[FFmpegSubtitleBitmap alloc] init];
              bitmap.data = bitmapData;
              bitmap.width = w;
              bitmap.height = h;
              bitmap.normalizedX = normX;
              bitmap.normalizedY = normY;
              bitmap.normalizedWidth = normW;
              bitmap.normalizedHeight = normH;

              [bitmaps addObject:bitmap];
            }
          }
        }
      }
    }

    if (bitmaps.count > 0) {
      frame.bitmaps = bitmaps;
    } else if (fullText.length > 0) {
      frame.text = fullText;
    }
  }

  avsubtitle_free(&subtitle);
  return frame;
}

#pragma mark - Decoder Flushing & Draining

- (void)flushVideoDecoder {
  if (!_codecContext) {
    return;
  }
  // Send NULL packet to signal end of stream
  // This tells the decoder to output all remaining buffered frames
  avcodec_send_packet(_codecContext, NULL);
}

- (nullable FFmpegVideoFrame *)drainVideoFrame {
  if (!_codecContext) {
    return nil;
  }

  // Receive any remaining buffered frames
  int ret = avcodec_receive_frame(_codecContext, _frame);

  if (ret == AVERROR_EOF) {
    // No more frames - decoder is fully drained

    return nil;
  }

  if (ret == AVERROR(EAGAIN) || ret < 0) {
    // Shouldn't happen after flush, but handle gracefully
    return nil;
  }

  double pts = 0.0;
  if (_frame->pts != AV_NOPTS_VALUE) {
    if (_videoTimeBaseDen > 0) {
      pts = (double)_frame->pts * (double)_videoTimeBaseNum /
            (double)_videoTimeBaseDen;
    }
  }

  return [self createVideoFrameFromDecodedFrame:pts];
}

- (void)flushAudioDecoder {
  if (!_audioCodecContext) {
    return;
  }
  // Send NULL packet to signal end of stream for audio decoder
  avcodec_send_packet(_audioCodecContext, NULL);
}

- (nullable FFmpegAudioFrame *)drainAudioFrame {
  if (!_audioCodecContext) {
    return nil;
  }

  int ret = avcodec_receive_frame(_audioCodecContext, _audioFrame);

  if (ret == AVERROR_EOF) {
    return nil;
  }

  if (ret == AVERROR(EAGAIN) || ret < 0) {
    return nil;
  }

  AVAudioPCMBuffer *pcmBuffer = [self convertAudioFrame:_audioFrame];
  if (!pcmBuffer) {
    return nil;
  }

  double pts = 0.0;
  bool hasPTS = false;
  int64_t ts = _audioFrame->pts;
  if (ts == AV_NOPTS_VALUE) {
    ts = _audioFrame->best_effort_timestamp;
  }
  if (ts != AV_NOPTS_VALUE && _audioTimeBaseDen > 0) {
    pts = (double)ts * (double)_audioTimeBaseNum / (double)_audioTimeBaseDen;
    hasPTS = true;
  } else if (_audioNextPTS >= 0.0) {
    pts = _audioNextPTS;
  }

  double duration = 0.0;
  if (pcmBuffer.frameLength > 0) {
    duration =
        (double)pcmBuffer.frameLength / (double)pcmBuffer.format.sampleRate;
  }

  if (_audioNextPTS >= 0.0 && hasPTS && pts < _audioNextPTS - 0.000001) {
    // Enforce monotonic audio PTS for system renderer stability.
    pts = _audioNextPTS;
  }
  _audioNextPTS = pts + duration;

  FFmpegAudioFrame *audioFrame = [[FFmpegAudioFrame alloc] init];
  audioFrame.type = FFmpegFrameTypeAudio;
  audioFrame.pcmBuffer = pcmBuffer;
  audioFrame.presentationTime = pts;
  return audioFrame;
}

- (void)flushCodecBuffers {
  if (_codecContext) {
    avcodec_flush_buffers(_codecContext);
  }
  if (_audioCodecContext) {
    avcodec_flush_buffers(_audioCodecContext);
  }
  if (_subtitleCodecContext) {
    avcodec_flush_buffers(_subtitleCodecContext);
  }
  _audioNextPTS = -1.0;
}

- (BOOL)switchSubtitleStream:(NSDictionary<NSString *, id> *)config {
  if (!config[@"subtitleCodecId"])
    return NO;

  if (_subtitleCodecContext) {
    avcodec_free_context(&_subtitleCodecContext);
    _subtitleCodecContext = NULL;
  }

  int codecId = [config[@"subtitleCodecId"] intValue];
  const AVCodec *codec = avcodec_find_decoder((enum AVCodecID)codecId);
  if (!codec)
    return NO;

  _subtitleCodecContext = avcodec_alloc_context3(codec);
  if (!_subtitleCodecContext)
    return NO;

  _subtitleTimeBaseNum = [config[@"subtitleTimeBaseNum"] intValue];
  _subtitleTimeBaseDen = [config[@"subtitleTimeBaseDen"] intValue];

  if (config[@"subtitleExtradata"]) {
    NSData *extra = config[@"subtitleExtradata"];
    _subtitleCodecContext->extradata =
        (uint8_t *)av_malloc(extra.length + AV_INPUT_BUFFER_PADDING_SIZE);
    memcpy(_subtitleCodecContext->extradata, extra.bytes, extra.length);
    _subtitleCodecContext->extradata_size = (int)extra.length;
  }

  if (avcodec_open2(_subtitleCodecContext, codec, NULL) < 0) {
    avcodec_free_context(&_subtitleCodecContext);
    _subtitleCodecContext = NULL;
    return NO;
  }

  _subtitleStreamIndex = [config[@"subtitleStreamIndex"] intValue];
  return YES;
}

- (BOOL)switchAudioStream:(NSDictionary<NSString *, id> *)config {
  // Validate audio config is present
  if (!config[@"audioCodecId"]) {
    return NO;
  }

  // Clean up old audio context and resampler
  if (_audioCodecContext) {
    avcodec_free_context(&_audioCodecContext);
    _audioCodecContext = NULL;
  }
  _audioNextPTS = -1.0;

  if (_swrContext) {
    swr_free(&_swrContext);
    _swrContext = NULL;
  }

  // Reset audio time base
  _audioTimeBaseNum = [config[@"audioTimeBaseNum"] intValue];
  _audioTimeBaseDen = [config[@"audioTimeBaseDen"] intValue];

  // Initialize new audio codec
  int audioCodecId = [config[@"audioCodecId"] intValue];
  const AVCodec *audioCodec =
      avcodec_find_decoder((enum AVCodecID)audioCodecId);
  if (!audioCodec) {
    return NO;
  }

  _audioCodecContext = avcodec_alloc_context3(audioCodec);
  if (!_audioCodecContext) {
    return NO;
  }

  // Set audio parameters
  _audioCodecContext->sample_rate = [config[@"audioSampleRate"] intValue];
  av_channel_layout_default(&_audioCodecContext->ch_layout,
                            [config[@"audioChannels"] intValue]);

  // Set extradata if present
  NSData *audioExtradata = config[@"audioExtradata"];
  if (audioExtradata && audioExtradata.length > 0) {
    _audioCodecContext->extradata = (uint8_t *)av_malloc(
        audioExtradata.length + AV_INPUT_BUFFER_PADDING_SIZE);
    if (_audioCodecContext->extradata) {
      memcpy(_audioCodecContext->extradata, audioExtradata.bytes,
             audioExtradata.length);
      _audioCodecContext->extradata_size = (int)audioExtradata.length;
    }
  }

  // Open the codec
  if (avcodec_open2(_audioCodecContext, audioCodec, NULL) < 0) {
    avcodec_free_context(&_audioCodecContext);
    _audioCodecContext = NULL;
    return NO;
  }

  _audioStreamIndex = [config[@"audioStreamIndex"] intValue];
  if (_audioStreamIndex == 0 && config[@"audioStreamIndex"] == nil) {
    _audioStreamIndex = 1; // Fallback
  }

  // Update videoInfo with new audio details
  _videoInfo.audioCodecName = [NSString stringWithUTF8String:audioCodec->name];
  _videoInfo.audioSampleRate = _audioCodecContext->sample_rate;
  _videoInfo.audioChannels = _audioCodecContext->ch_layout.nb_channels;

  return YES;
}

#pragma mark - Internal Frame Conversion & Processing

- (AVAudioPCMBuffer *)convertAudioFrame:(AVFrame *)frame {
  // Initialize SwrContext if needed
  const int outSampleRate =
      frame->sample_rate > 0 ? frame->sample_rate : kAudioSampleRateFallback;
  const int outChannels = frame->ch_layout.nb_channels > 0
                              ? frame->ch_layout.nb_channels
                              : kAudioChannelsFallback;

  // Ensure output frame properties are set (av_frame_unref clears them)
  av_channel_layout_uninit(&_swrOutputFrame->ch_layout);
  if (frame->ch_layout.nb_channels > 0) {
    av_channel_layout_copy(&_swrOutputFrame->ch_layout, &frame->ch_layout);
  } else {
    av_channel_layout_default(&_swrOutputFrame->ch_layout, outChannels);
  }
  _swrOutputFrame->sample_rate = outSampleRate;
  _swrOutputFrame->format = kAudioSampleFormat;

  // Initialize SwrContext if needed
  const int srcSampleRate =
      frame->sample_rate > 0 ? frame->sample_rate : outSampleRate;
  const int srcChannels = frame->ch_layout.nb_channels > 0
                              ? frame->ch_layout.nb_channels
                              : outChannels;
  const enum AVSampleFormat srcFormat = (enum AVSampleFormat)frame->format;

  if (!_swrContext || _swrSrcSampleRate != srcSampleRate ||
      _swrSrcChannels != srcChannels || _swrSrcFormat != srcFormat) {
    if (_swrContext) {
      swr_free(&_swrContext);
    }
    int ret =
        swr_alloc_set_opts2(&_swrContext, &_swrOutputFrame->ch_layout,
                            (enum AVSampleFormat)_swrOutputFrame->format,
                            _swrOutputFrame->sample_rate, &frame->ch_layout,
                            srcFormat, srcSampleRate, 0, NULL);

    if (ret < 0 || swr_init(_swrContext) < 0) {
      if (_swrContext)
        swr_free(&_swrContext);
      return nil;
    }

    _swrSrcSampleRate = srcSampleRate;
    _swrSrcChannels = srcChannels;
    _swrSrcFormat = srcFormat;
  }

  // Convert
  // Calculate expected number of output samples
  int ret = swr_convert_frame(_swrContext, _swrOutputFrame, frame);

  if (ret < 0) {

    return nil;
  }

  // Create AVAudioPCMBuffer
  AVAudioChannelLayout *channelLayout =
      CreateChannelLayoutFromFFmpeg(&_swrOutputFrame->ch_layout, outChannels);
  AVAudioFormat *format = nil;
  if (channelLayout) {
    format = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                              sampleRate:outSampleRate
                                             interleaved:NO
                                           channelLayout:channelLayout];
  } else {
    format = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                              sampleRate:outSampleRate
                                                channels:outChannels
                                             interleaved:NO];
  }
  if (!format)
    return nil;

  AVAudioPCMBuffer *buffer =
      [[AVAudioPCMBuffer alloc] initWithPCMFormat:format
                                    frameCapacity:_swrOutputFrame->nb_samples];
  if (!buffer)
    return nil;

  buffer.frameLength = _swrOutputFrame->nb_samples;

  // Copy data
  // AVAudioEngine standard format is Float32, non-interleaved (Planar).
  // Thus, we use AV_SAMPLE_FMT_FLTP for the resampling output.

  // Copying data:
  for (int ch = 0; ch < outChannels; ch++) {
    float *dest = buffer.floatChannelData[ch];
    float *src = (float *)_swrOutputFrame->data[ch];
    memcpy(dest, src, _swrOutputFrame->nb_samples * sizeof(float));
  }

  // Cleanup output frame data for next use (swr_convert_frame allocates it)
  av_frame_unref(_swrOutputFrame);

  return buffer;
}

- (CVPixelBufferRef)extractPixelBufferFromHardwareFrame:(AVFrame *)frame {
  // VideoToolbox stores the CVPixelBuffer in frame->data[3]
  CVPixelBufferRef pixelBuffer = (CVPixelBufferRef)frame->data[3];

  if (pixelBuffer) {
    // Retain since we're giving ownership to the caller
    CVPixelBufferRetain(pixelBuffer);
    return pixelBuffer;
  }

  return NULL;
}

- (CVPixelBufferRef)convertFrameToPixelBuffer:(AVFrame *)frame {
  return [_pixelFormatConverter convertFrame:frame];
}

#pragma mark - Seeking

/// Creates a video frame from the currently decoded frame in _frame.
/// @param pts Presentation timestamp in seconds
/// @return A new FFmpegVideoFrame or nil if pixel buffer creation fails
- (nullable FFmpegVideoFrame *)createVideoFrameFromDecodedFrame:(double)pts {
  CVPixelBufferRef pixelBuffer = NULL;
  if (_usingHardwareDecoder && _frame->format == _hwPixelFormat) {
    pixelBuffer = [self extractPixelBufferFromHardwareFrame:_frame];
  } else {
    pixelBuffer = [self convertFrameToPixelBuffer:_frame];
  }

  if (!pixelBuffer) {
    return nil;
  }

  FFmpegVideoFrame *videoFrame = [[FFmpegVideoFrame alloc] init];
  videoFrame.type = FFmpegFrameTypeVideo;
  videoFrame.pixelBuffer = pixelBuffer;
  videoFrame.presentationTime = pts;
  videoFrame.doviProfile = _videoInfo.doviProfile;

  // Extract Ambient Viewing Environment side data if present
  AVFrameSideData *sd =
      av_frame_get_side_data(_frame, AV_FRAME_DATA_AMBIENT_VIEWING_ENVIRONMENT);
  if (sd && sd->size >= sizeof(AVAmbientViewingEnvironment)) {
    videoFrame.ambientLightMetadata = [NSData dataWithBytes:sd->data
                                                     length:sd->size];
  }

  return videoFrame;
}

#pragma mark - Cleanup

- (void)close {
  // Guard against double-close (dealloc also calls close)
  if (_isClosed) {
    return;
  }
  _isClosed = YES;

  if (_swrContext) {
    swr_free(&_swrContext);
    _swrContext = NULL;
  }

  if (_frame) {
    av_frame_free(&_frame);
    _frame = NULL;
  }

  if (_swFrame) {
    av_frame_free(&_swFrame);
    _swFrame = NULL;
  }

  if (_audioFrame) {
    av_frame_free(&_audioFrame);
    _audioFrame = NULL;
  }

  if (_swrOutputFrame) {
    av_frame_free(&_swrOutputFrame);
    _swrOutputFrame = NULL;
  }

  if (_packet) {
    av_packet_free(&_packet);
    _packet = NULL;
  }

  if (_codecContext) {
    avcodec_free_context(&_codecContext);
    _codecContext = NULL;
  }

  if (_audioCodecContext) {
    avcodec_free_context(&_audioCodecContext);
    _audioCodecContext = NULL;
  }

  if (_subtitleCodecContext) {
    avcodec_free_context(&_subtitleCodecContext);
    _subtitleCodecContext = NULL;
  }

  if (_hwDeviceCtx) {
    av_buffer_unref(&_hwDeviceCtx);
    _hwDeviceCtx = NULL;
  }

  // Cleanup pixel format converter (handles I420 and P010 buffer pools)
  [_pixelFormatConverter cleanup];
  _pixelFormatConverter = nil;

  _usingHardwareDecoder = NO;
}
@end
