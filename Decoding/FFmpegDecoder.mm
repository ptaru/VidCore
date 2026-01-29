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

#pragma mark - FFmpegPacketData

@implementation FFmpegPacketData
@end

@interface FFmpegDecoder ()

@property(nonatomic, assign)
    AVCodecContext *codecContext; // Video codec context
// VTDecoder now handled by Swift VideoDecoder
@property(nonatomic, assign)
    AVCodecContext *audioCodecContext; // Audio codec context
@property(nonatomic, assign) SwsContext *swsContext;
@property(nonatomic, assign) SwrContext *swrContext;
@property(nonatomic, assign) AVFrame *frame;
@property(nonatomic, assign) AVFrame *swFrame; // For hardware frame transfer
@property(nonatomic, assign) AVFrame *audioFrame;
@property(nonatomic, assign) AVFrame *swrOutputFrame; // For resampled audio
@property(nonatomic, assign) AVPacket *packet;
@property(nonatomic, assign) int videoStreamIndex;
@property(nonatomic, assign) int audioStreamIndex;
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
@end
#pragma mark - Internal Helper Functions

// Constants for audio conversion
static const int kAudioSampleRate = 48000;
static const enum AVSampleFormat kAudioSampleFormat = AV_SAMPLE_FMT_FLTP;
static const int kAudioChannels = 2; // Stereo



// Static variable to store the expected hw pixel format for the callback
static enum AVPixelFormat s_hwPixelFormat = AV_PIX_FMT_NONE;

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



- (nullable instancetype)initWithDemuxerConfig:(NSDictionary<NSString *, id> *)config
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
    _swsContext = NULL;
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
        *error = [NSError errorWithDomain:@"FFmpegDecoder" code:2001
                                 userInfo:@{NSLocalizedDescriptionKey: @"Codec not found"}];
      }
      return nil;
    }
    
    // Allocate video codec context
    _codecContext = avcodec_alloc_context3(codec);
    if (!_codecContext) {
      if (error) {
        *error = [NSError errorWithDomain:@"FFmpegDecoder" code:2002
                                 userInfo:@{NSLocalizedDescriptionKey: @"Failed to allocate codec context"}];
      }
      return nil;
    }
    
    // Set codec parameters
    _codecContext->width = width;
    _codecContext->height = height;
    _codecContext->pix_fmt = (enum AVPixelFormat)pixelFormat;
    _codecContext->color_primaries = (enum AVColorPrimaries)[config[@"colorPrimaries"] intValue];
    _codecContext->color_trc = (enum AVColorTransferCharacteristic)[config[@"colorTransfer"] intValue];
    _codecContext->colorspace = (enum AVColorSpace)[config[@"colorSpace"] intValue];
    _codecContext->color_range = (enum AVColorRange)[config[@"colorRange"] intValue];
    
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
      _codecContext->extradata = (uint8_t *)av_malloc(videoExtradata.length + AV_INPUT_BUFFER_PADDING_SIZE);
      if (_codecContext->extradata) {
        memcpy(_codecContext->extradata, videoExtradata.bytes, videoExtradata.length);
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
        *error = [NSError errorWithDomain:@"FFmpegDecoder" code:2003
                                 userInfo:@{NSLocalizedDescriptionKey: @"Failed to open codec"}];
      }
      avcodec_free_context(&_codecContext);
      return nil;
    }
    
    // Setup audio codec if present
    if (config[@"audioCodecId"]) {
      int audioCodecId = [config[@"audioCodecId"] intValue];
      const AVCodec *audioCodec = avcodec_find_decoder((enum AVCodecID)audioCodecId);
      if (audioCodec) {
        _audioCodecContext = avcodec_alloc_context3(audioCodec);
        if (_audioCodecContext) {
          _audioCodecContext->sample_rate = [config[@"audioSampleRate"] intValue];
          av_channel_layout_default(&_audioCodecContext->ch_layout, [config[@"audioChannels"] intValue]);
          
          NSData *audioExtradata = config[@"audioExtradata"];
          if (audioExtradata && audioExtradata.length > 0) {
            _audioCodecContext->extradata = (uint8_t *)av_malloc(audioExtradata.length + AV_INPUT_BUFFER_PADDING_SIZE);
            if (_audioCodecContext->extradata) {
              memcpy(_audioCodecContext->extradata, audioExtradata.bytes, audioExtradata.length);
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
    
    // Allocate frames
    _frame = av_frame_alloc();
    _swFrame = av_frame_alloc();
    _audioFrame = av_frame_alloc();
    _swrOutputFrame = av_frame_alloc();
    _packet = av_packet_alloc();
    
    if (!_frame || !_swFrame || !_packet || !_audioFrame || !_swrOutputFrame) {
      if (error) {
        *error = [NSError errorWithDomain:@"FFmpegDecoder" code:2004
                                 userInfo:@{NSLocalizedDescriptionKey: @"Failed to allocate frames"}];
      }
      [self close];
      return nil;
    }
    
    // Initialize scaler for software path
    if (!_usingHardwareDecoder) {
      _swsContext = sws_getContext(width, height, (enum AVPixelFormat)pixelFormat,
                                   width, height, AV_PIX_FMT_NV12,
                                   SWS_BILINEAR, NULL, NULL, NULL);
    }
    
    // Create video info
    _videoInfo = [[FFmpegVideoInfo alloc] init];
    _videoInfo.width = width;
    _videoInfo.height = height;
    _videoInfo.codecName = [NSString stringWithUTF8String:codec->name];
    _videoInfo.isHardwareAccelerated = _usingHardwareDecoder;
    _videoInfo.decoderName = _usingHardwareDecoder 
        ? [NSString stringWithFormat:@"%s_videotoolbox", codec->name]
        : [NSString stringWithFormat:@"%s", codec->name];
    _videoInfo.decoderDescription = _usingHardwareDecoder 
        ? @"Hardware Acceleration (VideoToolbox)" 
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
      const AVCodec *audioCodec = avcodec_find_decoder((enum AVCodecID)[config[@"audioCodecId"] intValue]);
      if (audioCodec) {
        _videoInfo.audioCodecName = [NSString stringWithUTF8String:audioCodec->name];
      }
      _videoInfo.audioSampleRate = [config[@"audioSampleRate"] intValue];
      _videoInfo.audioChannels = [config[@"audioChannels"] intValue];
    }
    
    NSLog(@"[FFmpegDecoder] Initialized  (HW: %@)", _usingHardwareDecoder ? @"YES" : @"NO");
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

/// Helper to create FFmpegPacketData from AVPacket
- (FFmpegPacketData *)createPacketDataFromAVPacket:(AVPacket *)pkt
                                           isVideo:(BOOL)isVideo
                                           isAudio:(BOOL)isAudio {
  FFmpegPacketData *packetData = [[FFmpegPacketData alloc] init];
  packetData.streamIndex = pkt->stream_index;
  packetData.pts = pkt->pts;
  packetData.dts = pkt->dts;
  packetData.duration = pkt->duration;
  packetData.flags = pkt->flags;
  packetData.isVideo = isVideo;
  packetData.isAudio = isAudio;

  if (pkt->data && pkt->size > 0) {
    packetData.data = [NSData dataWithBytes:pkt->data length:pkt->size];
    packetData.size = pkt->size;
  } else {
    packetData.data = [NSData data];
    packetData.size = 0;
  }
  
  // Extract Ambient Viewing Environment side data
  const AVPacketSideData *amveSideData = av_packet_side_data_get(
      pkt->side_data, pkt->side_data_elems, AV_PKT_DATA_AMBIENT_VIEWING_ENVIRONMENT);
  if (amveSideData && amveSideData->size > 0) {
      packetData.ambientLightMetadata = [NSData dataWithBytes:amveSideData->data length:amveSideData->size];
  }
  
  return packetData;
}

/// Decode a video packet and return ALL available frames
/// With multi-threaded decoding, the decoder may have multiple frames ready
- (nullable NSArray<FFmpegVideoFrame *> *)decodeVideoPacket:(AVPacket *)pkt {
  // Note: Swift VTDecoder is now used by VideoDecoder.swift for H264/HEVC
  // This method handles FFmpeg software and FFmpeg-VideoToolbox paths

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
          pts = (double)finalPts * (double)_videoTimeBaseNum / (double)_videoTimeBaseDen;
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
  if (avcodec_send_packet(_audioCodecContext, pkt) < 0) {
    return nil;
  }

  int ret = avcodec_receive_frame(_audioCodecContext, _audioFrame);
  if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF || ret < 0) {
    return nil;
  }

  AVAudioPCMBuffer *pcmBuffer = [self convertAudioFrame:_audioFrame];
  if (!pcmBuffer) {
    return nil;
  }

  double pts = 0.0;
    if (_audioFrame->pts != AV_NOPTS_VALUE) {
        if (_audioTimeBaseDen > 0) {
            pts = (double)_audioFrame->pts * (double)_audioTimeBaseNum / (double)_audioTimeBaseDen;
        }
    }

  FFmpegAudioFrame *audioFrame = [[FFmpegAudioFrame alloc] init];
  audioFrame.type = FFmpegFrameTypeAudio;
  audioFrame.pcmBuffer = pcmBuffer;
  audioFrame.presentationTime = pts;

  return audioFrame;
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
          pts = (double)_frame->pts * (double)_videoTimeBaseNum / (double)_videoTimeBaseDen;
      }
  }

  return [self createVideoFrameFromDecodedFrame:pts];
}

- (void)flushCodecBuffers {
  if (_codecContext) {
    avcodec_flush_buffers(_codecContext);
  }
  if (_audioCodecContext) {
    avcodec_flush_buffers(_audioCodecContext);
  }
}

#pragma mark - Internal Frame Conversion & Processing

- (AVAudioPCMBuffer *)convertAudioFrame:(AVFrame *)frame {
  // Initialize SwrContext if needed
  // Ensure output frame properties are set (av_frame_unref clears them)
  av_channel_layout_default(&_swrOutputFrame->ch_layout, kAudioChannels);
  _swrOutputFrame->sample_rate = kAudioSampleRate;
  _swrOutputFrame->format = kAudioSampleFormat;

  // Initialize SwrContext if needed
  if (!_swrContext) {
    int ret = swr_alloc_set_opts2(
        &_swrContext, &_swrOutputFrame->ch_layout,
        (enum AVSampleFormat)_swrOutputFrame->format,
        _swrOutputFrame->sample_rate, &frame->ch_layout,
        (enum AVSampleFormat)frame->format, frame->sample_rate, 0, NULL);

    if (ret < 0 || swr_init(_swrContext) < 0) {

      if (_swrContext)
        swr_free(&_swrContext);
      return nil;
    }
  }

  // Convert
  // Calculate expected number of output samples
  int ret = swr_convert_frame(_swrContext, _swrOutputFrame, frame);

  if (ret < 0) {

    return nil;
  }

  // Create AVAudioPCMBuffer
  AVAudioFormat *format =
      [[AVAudioFormat alloc] initStandardFormatWithSampleRate:kAudioSampleRate
                                                     channels:kAudioChannels];
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
  for (int ch = 0; ch < kAudioChannels; ch++) {
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
  return videoFrame;
}

- (nullable FFmpegVideoFrame *)createVideoFrameFromPixelBuffer:(CVPixelBufferRef)pixelBuffer pts:(double)pts {
    if (!pixelBuffer) return nil;
    
    FFmpegVideoFrame *videoFrame = [[FFmpegVideoFrame alloc] init];
    videoFrame.type = FFmpegFrameTypeVideo;
    videoFrame.pixelBuffer = pixelBuffer;
    videoFrame.presentationTime = pts;
    videoFrame.doviProfile = _videoInfo.doviProfile;
    return videoFrame;
}



#pragma mark - Seek Implementation



#pragma mark - Cleanup

- (void)close {
  // Guard against double-close (dealloc also calls close)
  if (!_codecContext) {
    return;
  }

  NSLog(@"[FFmpegDecoder] Decoder closed and cleaned up");

  if (_swsContext) {
    sws_freeContext(_swsContext);
    _swsContext = NULL;
  }

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



  if (_hwDeviceCtx) {
    av_buffer_unref(&_hwDeviceCtx);
    _hwDeviceCtx = NULL;
  }

  // Cleanup pixel format converter (handles I420 and P010 buffer pools)
  [_pixelFormatConverter cleanup];
  _pixelFormatConverter = nil;

  // Note: VTDecoder is now managed by Swift VideoDecoder

  _usingHardwareDecoder = NO;
  NSLog(@"[FFmpegDecoder] close() completed - all resources freed");
}
@end
