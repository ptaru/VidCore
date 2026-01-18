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
@property(nonatomic, assign) AVFormatContext *formatContext;
@property(nonatomic, assign)
    AVCodecContext *codecContext; // Video codec context
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
// CVPixelBufferPool for efficient I420 buffer reuse (reduces memory
// fragmentation)
@property(nonatomic, assign) CVPixelBufferPoolRef i420BufferPool;
@property(nonatomic, assign) int poolWidth;
@property(nonatomic, assign) int poolHeight;
// Pool for P010 (HDR) frames
@property(nonatomic, assign) CVPixelBufferPoolRef p010BufferPool;
@property(nonatomic, assign) BOOL hasCreatedP010Pool;
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
  NSLog(@"[FFmpegDecoder] Hardware pixel format not available, using software");
  return pix_fmts[0];
}

#pragma mark - FFmpegDecoder Implementation

@implementation FFmpegDecoder

#pragma mark - Initialization & Lifecycle

- (instancetype)initWithURL:(NSURL *)url error:(NSError **)error {
  self = [super init];
  if (self) {
    // Set log level to ERROR to avoid noisy hevc logs
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
      av_log_set_level(AV_LOG_ERROR);
    });
    _formatContext = NULL;
    _codecContext = NULL;
    _audioCodecContext = NULL;
    _swsContext = NULL;
    _swrContext = NULL;
    _frame = NULL;
    _swFrame = NULL;
    _audioFrame = NULL;
    _swrOutputFrame = NULL;
    _packet = NULL;
    _videoStreamIndex = -1;
    _audioStreamIndex = -1;
    _hwDeviceCtx = NULL;
    _usingHardwareDecoder = NO;
    _hwPixelFormat = AV_PIX_FMT_VIDEOTOOLBOX;
    _seekOptimizationEnabled = YES; // Enable by default
    _i420BufferPool = NULL;
    _poolWidth = 0;
    _poolHeight = 0;
    _p010BufferPool = NULL;
    _hasCreatedP010Pool = NO;

    if (![self openVideoFile:url error:error]) {
      return nil;
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
    NSLog(@"[FFmpegDecoder] Failed to create VideoToolbox device context: %s",
          av_err2str(ret));
    return NO;
  }

  // Verify the codec supports VideoToolbox
  for (int i = 0;; i++) {
    const AVCodecHWConfig *config = avcodec_get_hw_config(codec, i);
    if (!config) {
      NSLog(@"[FFmpegDecoder] Codec %s does not support VideoToolbox",
            codec->name);
      av_buffer_unref(&_hwDeviceCtx);
      _hwDeviceCtx = NULL;
      return NO;
    }
    if (config->methods & AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX &&
        config->device_type == AV_HWDEVICE_TYPE_VIDEOTOOLBOX) {
      _hwPixelFormat = config->pix_fmt;
      s_hwPixelFormat = _hwPixelFormat;
      NSLog(@"[FFmpegDecoder] VideoToolbox supported for codec %s",
            codec->name);
      break;
    }
  }

  return YES;
}

- (BOOL)openVideoFile:(NSURL *)url error:(NSError **)error {
  const char *filename = [[url path] UTF8String];

  // Open input file
  if (avformat_open_input(&_formatContext, filename, NULL, NULL) < 0) {
    if (error) {
      *error = [NSError
          errorWithDomain:@"FFmpegDecoder"
                     code:1001
                 userInfo:@{
                   NSLocalizedDescriptionKey : @"Failed to open video file"
                 }];
    }
    return NO;
  }

  // Retrieve stream information
  if (avformat_find_stream_info(_formatContext, NULL) < 0) {
    if (error) {
      *error = [NSError errorWithDomain:@"FFmpegDecoder"
                                   code:1002
                               userInfo:@{
                                 NSLocalizedDescriptionKey :
                                     @"Failed to find stream information"
                               }];
    }
    [self close];
    return NO;
  }

  // Find the best video stream
  _videoStreamIndex =
      av_find_best_stream(_formatContext, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
  if (_videoStreamIndex < 0) {
    if (error) {
      *error =
          [NSError errorWithDomain:@"FFmpegDecoder"
                              code:1003
                          userInfo:@{
                            NSLocalizedDescriptionKey : @"No video stream found"
                          }];
    }
    [self close];
    return NO;
  }

  AVStream *videoStream = _formatContext->streams[_videoStreamIndex];

  // Find decoder for the video stream
  const AVCodec *codec = avcodec_find_decoder(videoStream->codecpar->codec_id);
  if (!codec) {
    if (error) {
      *error = [NSError
          errorWithDomain:@"FFmpegDecoder"
                     code:1004
                 userInfo:@{NSLocalizedDescriptionKey : @"Codec not found"}];
    }
    [self close];
    return NO;
  }

  // Try to initialize hardware decoder
  BOOL hwInitSuccess = [self initHardwareDecoder:codec error:nil];

  // Allocate codec context
  _codecContext = avcodec_alloc_context3(codec);
  if (!_codecContext) {
    if (error) {
      *error = [NSError errorWithDomain:@"FFmpegDecoder"
                                   code:1005
                               userInfo:@{
                                 NSLocalizedDescriptionKey :
                                     @"Failed to allocate codec context"
                               }];
    }
    [self close];
    return NO;
  }

  // Copy codec parameters to codec context
  if (avcodec_parameters_to_context(_codecContext, videoStream->codecpar) < 0) {
    if (error) {
      *error = [NSError errorWithDomain:@"FFmpegDecoder"
                                   code:1006
                               userInfo:@{
                                 NSLocalizedDescriptionKey :
                                     @"Failed to copy codec parameters"
                               }];
    }
    [self close];
    return NO;
  }

  // Configure hardware acceleration if available
  if (hwInitSuccess && _hwDeviceCtx) {
    _codecContext->hw_device_ctx = av_buffer_ref(_hwDeviceCtx);
    _codecContext->get_format = get_hw_format;
    _usingHardwareDecoder = YES;
    NSLog(@"[FFmpegDecoder] Configured hardware decoding with VideoToolbox");
  } else {
    // Enable multi-threaded decoding for software decode path
    // 0 = auto-detect optimal thread count based on CPU cores
    _codecContext->thread_count = 0;
    // Enable both frame threading (decode multiple frames in parallel) and
    // slice threading (decode slices of a single frame in parallel)
    _codecContext->thread_type = FF_THREAD_FRAME | FF_THREAD_SLICE;
    NSLog(@"[FFmpegDecoder] Using software decoding with multi-threading (auto "
          @"threads)");
  }

  // Open codec
  int ret = avcodec_open2(_codecContext, codec, NULL);
  if (ret < 0) {
    // If hardware decoding failed to open, try falling back to software
    if (_usingHardwareDecoder) {
      NSLog(@"[FFmpegDecoder] Hardware codec open failed, falling back to "
            @"software: %s",
            av_err2str(ret));

      // Reset hardware state
      av_buffer_unref(&_hwDeviceCtx);
      _hwDeviceCtx = NULL;
      _codecContext->hw_device_ctx = NULL;
      _codecContext->get_format = NULL;
      _usingHardwareDecoder = NO;

      // Try opening again with software
      ret = avcodec_open2(_codecContext, codec, NULL);
    }

    if (ret < 0) {
      if (error) {
        *error = [NSError
            errorWithDomain:@"FFmpegDecoder"
                       code:1007
                   userInfo:@{
                     NSLocalizedDescriptionKey : @"Failed to open codec"
                   }];
      }
      [self close];
      return NO;
    }
  }

  // Find the best audio stream (optional)
  _audioStreamIndex =
      av_find_best_stream(_formatContext, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);

  if (_audioStreamIndex >= 0) {
    AVStream *audioStream = _formatContext->streams[_audioStreamIndex];
    const AVCodec *audioCodec =
        avcodec_find_decoder(audioStream->codecpar->codec_id);

    if (audioCodec) {
      _audioCodecContext = avcodec_alloc_context3(audioCodec);
      if (_audioCodecContext) {
        if (avcodec_parameters_to_context(_audioCodecContext,
                                          audioStream->codecpar) >= 0) {
          if (avcodec_open2(_audioCodecContext, audioCodec, NULL) >= 0) {
            NSLog(
                @"[FFmpegDecoder] Opened audio stream: %s, %d Hz, %d channels",
                audioCodec->name, _audioCodecContext->sample_rate,
                _audioCodecContext->ch_layout.nb_channels);
          } else {
            NSLog(@"[FFmpegDecoder] Failed to open audio codec");
            avcodec_free_context(&_audioCodecContext);
            _audioCodecContext = NULL;
            _audioStreamIndex = -1;
          }
        } else {
          avcodec_free_context(&_audioCodecContext);
          _audioCodecContext = NULL;
          _audioStreamIndex = -1;
        }
      }
    }
  } else {
    NSLog(@"[FFmpegDecoder] No audio stream found");
  }

  // Allocate frames
  _frame = av_frame_alloc();
  _swFrame = av_frame_alloc(); // For transferring hw frames to sw
  _audioFrame = av_frame_alloc();
  _swrOutputFrame = av_frame_alloc();
  _packet = av_packet_alloc();

  if (!_frame || !_swFrame || !_packet || !_audioFrame || !_swrOutputFrame) {
    if (error) {
      *error = [NSError errorWithDomain:@"FFmpegDecoder"
                                   code:1008
                               userInfo:@{
                                 NSLocalizedDescriptionKey :
                                     @"Failed to allocate frame or packet"
                               }];
    }
    [self close];
    return NO;
  }

  // Initialize scaler context for YUV to BGRA conversion (only used for
  // software path) For hardware path, we get CVPixelBuffer directly
  if (!_usingHardwareDecoder) {
    // Use NV12 output format for accelerated conversion (no CPU YUV→RGB)
    // Core Image handles YUV→RGB on the GPU when rendering
    _swsContext = sws_getContext(_codecContext->width, _codecContext->height,
                                 _codecContext->pix_fmt, _codecContext->width,
                                 _codecContext->height, AV_PIX_FMT_NV12,
                                 SWS_BILINEAR, NULL, NULL, NULL);

    if (!_swsContext) {
      if (error) {
        *error = [NSError errorWithDomain:@"FFmpegDecoder"
                                     code:1009
                                 userInfo:@{
                                   NSLocalizedDescriptionKey :
                                       @"Failed to create scaler context"
                                 }];
      }
      [self close];
      return NO;
    }
  }

  // Create video info
  _videoInfo = [[FFmpegVideoInfo alloc] init];
  _videoInfo.width = _codecContext->width;
  _videoInfo.height = _codecContext->height;
  _videoInfo.codecName = [NSString stringWithUTF8String:codec->name];
  _videoInfo.isHardwareAccelerated = _usingHardwareDecoder;

  // Extract color metadata for HDR detection
  _videoInfo.colorPrimaries = _codecContext->color_primaries;
  _videoInfo.colorTransfer = _codecContext->color_trc;
  _videoInfo.colorSpace = _codecContext->colorspace;
  _videoInfo.colorRange = _codecContext->color_range;

  // Check for Dolby Vision side data in the stream
  const AVPacketSideData *doviSideData = av_packet_side_data_get(
      videoStream->codecpar->coded_side_data,
      videoStream->codecpar->nb_coded_side_data, AV_PKT_DATA_DOVI_CONF);
  _videoInfo.isDolbyVision = (doviSideData != NULL);

  // Calculate bits per component from pixel format
  const AVPixFmtDescriptor *pixFmtDesc =
      av_pix_fmt_desc_get(_codecContext->pix_fmt);
  _videoInfo.bitsPerComponent = pixFmtDesc ? pixFmtDesc->comp[0].depth : 8;

  // Calculate frame rate
  AVRational frameRate = av_guess_frame_rate(_formatContext, videoStream, NULL);
  if (frameRate.num && frameRate.den) {
    _videoInfo.frameRate = (double)frameRate.num / (double)frameRate.den;
  } else {
    _videoInfo.frameRate = 30.0; // Default to 30fps
  }

  // Calculate duration
  if (videoStream->duration != AV_NOPTS_VALUE) {
    _videoInfo.duration =
        (double)videoStream->duration * av_q2d(videoStream->time_base);
  } else if (_formatContext->duration != AV_NOPTS_VALUE) {
    _videoInfo.duration = (double)_formatContext->duration / AV_TIME_BASE;
  } else {
    _videoInfo.duration = 0.0;
  }

  // Populate audio info if audio stream is available
  if (_audioStreamIndex >= 0 && _audioCodecContext) {
    AVStream *audioStream = _formatContext->streams[_audioStreamIndex];
    const AVCodec *audioCodec =
        avcodec_find_decoder(audioStream->codecpar->codec_id);
    if (audioCodec) {
      _videoInfo.audioCodecName =
          [NSString stringWithUTF8String:audioCodec->name];
    }
    _videoInfo.audioSampleRate = _audioCodecContext->sample_rate;
    _videoInfo.audioChannels = _audioCodecContext->ch_layout.nb_channels;
  }

  NSLog(
      @"[FFmpegDecoder] Opened video: %dx%d, %.2f fps, %.2f sec, codec: %s, "
      @"hardware: %@, HDR: %@, bits: %d",
      _videoInfo.width, _videoInfo.height, _videoInfo.frameRate,
      _videoInfo.duration, codec->name, _usingHardwareDecoder ? @"YES" : @"NO",
      _videoInfo.isDolbyVision ? @"DOVI" : (_videoInfo.isHDR ? @"YES" : @"NO"),
      _videoInfo.bitsPerComponent);

  return YES;
}

#pragma mark - Metadata Accessors

- (nullable FFmpegVideoInfo *)getVideoInfo {
  return _videoInfo;
}

#pragma mark - Demuxing & Decoding

- (nullable FFmpegPacketData *)demuxNextPacket {
  if (!_formatContext) {
    return nil;
  }

  // Allocate a temporary packet for demuxing
  AVPacket *pkt = av_packet_alloc();
  if (!pkt) {
    return nil;
  }

  while (av_read_frame(_formatContext, pkt) >= 0) {
    BOOL isVideo = (pkt->stream_index == _videoStreamIndex);
    BOOL isAudio =
        (pkt->stream_index == _audioStreamIndex && _audioCodecContext != NULL);

    // Only return video or audio packets
    if (isVideo || isAudio) {
      FFmpegPacketData *packetData = [[FFmpegPacketData alloc] init];
      packetData.streamIndex = pkt->stream_index;
      packetData.pts = pkt->pts;
      packetData.dts = pkt->dts;
      packetData.duration = pkt->duration;
      packetData.flags = pkt->flags;
      packetData.isVideo = isVideo;
      packetData.isAudio = isAudio;

      // Copy packet data to NSData
      if (pkt->data && pkt->size > 0) {
        packetData.data = [NSData dataWithBytes:pkt->data length:pkt->size];
        packetData.size = pkt->size;
      } else {
        packetData.data = [NSData data];
        packetData.size = 0;
      }

      av_packet_free(&pkt);
      return packetData;
    }

    // Skip non-video/audio packets
    av_packet_unref(pkt);
  }

  av_packet_free(&pkt);
  return nil;
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

/// Decode a video packet and return ALL available frames
/// With multi-threaded decoding, the decoder may have multiple frames ready
- (nullable NSArray<FFmpegVideoFrame *> *)decodeVideoPacket:(AVPacket *)pkt {
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

    CVPixelBufferRef pixelBuffer = NULL;
    if (_usingHardwareDecoder && _frame->format == _hwPixelFormat) {
      pixelBuffer = [self extractPixelBufferFromHardwareFrame:_frame];
    } else {
      pixelBuffer = [self convertFrameToPixelBuffer:_frame];
    }

    if (!pixelBuffer) {
      continue; // Skip this frame but keep draining
    }

    double pts = 0.0;
    if (_frame->pts != AV_NOPTS_VALUE) {
      AVStream *stream = _formatContext->streams[_videoStreamIndex];
      pts = (double)_frame->pts * av_q2d(stream->time_base);
    }

    FFmpegVideoFrame *videoFrame = [[FFmpegVideoFrame alloc] init];
    videoFrame.type = FFmpegFrameTypeVideo;
    videoFrame.pixelBuffer = pixelBuffer;
    videoFrame.presentationTime = pts;

    // Extract Dolby Vision Profile 5 metadata if present
    videoFrame.doviMetadata = [self extractDoViMetadataFromFrame:_frame];

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
    AVStream *stream = _formatContext->streams[_audioStreamIndex];
    pts = (double)_audioFrame->pts * av_q2d(stream->time_base);
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
  NSLog(@"[FFmpegDecoder] Video decoder flushed for draining");
}

- (nullable FFmpegVideoFrame *)drainVideoFrame {
  if (!_codecContext || !_formatContext) {
    return nil;
  }

  // Receive any remaining buffered frames
  int ret = avcodec_receive_frame(_codecContext, _frame);

  if (ret == AVERROR_EOF) {
    // No more frames - decoder is fully drained
    NSLog(@"[FFmpegDecoder] Video decoder fully drained");
    return nil;
  }

  if (ret == AVERROR(EAGAIN) || ret < 0) {
    // Shouldn't happen after flush, but handle gracefully
    return nil;
  }

  CVPixelBufferRef pixelBuffer = NULL;
  if (_usingHardwareDecoder && _frame->format == _hwPixelFormat) {
    pixelBuffer = [self extractPixelBufferFromHardwareFrame:_frame];
  } else {
    pixelBuffer = [self convertFrameToPixelBuffer:_frame];
  }

  if (!pixelBuffer) {
    return nil;
  }

  double pts = 0.0;
  if (_frame->pts != AV_NOPTS_VALUE) {
    AVStream *stream = _formatContext->streams[_videoStreamIndex];
    pts = (double)_frame->pts * av_q2d(stream->time_base);
  }

  FFmpegVideoFrame *videoFrame = [[FFmpegVideoFrame alloc] init];
  videoFrame.type = FFmpegFrameTypeVideo;
  videoFrame.pixelBuffer = pixelBuffer;
  videoFrame.presentationTime = pts;

  return videoFrame;
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
      NSLog(@"[FFmpegDecoder] Failed to initialize SwrContext");
      if (_swrContext)
        swr_free(&_swrContext);
      return nil;
    }
  }

  // Convert
  // Calculate expected number of output samples
  int ret = swr_convert_frame(_swrContext, _swrOutputFrame, frame);

  if (ret < 0) {
    NSLog(@"[FFmpegDecoder] Audio conversion failed");
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

  NSLog(@"[FFmpegDecoder] Failed to extract CVPixelBuffer from hardware frame");
  return NULL;
}

/// Extract Dolby Vision Profile 5 metadata from frame side data
/// Returns nil for Profile 8 or non-DoVi content (fallback to standard HDR)
- (nullable NSDictionary *)extractDoViMetadataFromFrame:(AVFrame *)frame {
  AVFrameSideData *sd =
      av_frame_get_side_data(frame, AV_FRAME_DATA_DOVI_METADATA);
  if (!sd)
    return nil;

  const AVDOVIMetadata *metadata = (AVDOVIMetadata *)sd->data;
  const AVDOVIRpuDataHeader *header = av_dovi_get_header(metadata);

  // CRITICAL: Only process Profile 5 (IPTPQc2)
  // Profile 5 uses full range video (bl_video_full_range_flag = 1)
  // Profile 8.x uses limited range with HDR10/HLG-compatible base layer
  // Applying IPTPQc2 pipeline to Profile 8 causes severe color corruption
  //
  // Note: Profile 5 is distinguished by:
  // - bl_video_full_range_flag = 1 (always full range)
  // - Single layer (disable_residual_flag = 1)
  // Profile 8 typically has:
  // - bl_video_full_range_flag = 0 (limited range, HDR10-compatible)
  // - disable_residual_flag = 1 (single layer variant)

  // Single-layer only (no enhancement layer)
  if (!header->disable_residual_flag) {
    static BOOL loggedEnhancementLayer = NO;
    if (!loggedEnhancementLayer) {
      NSLog(@"[FFmpegDecoder] DoVi enhancement layer present, not supported");
      loggedEnhancementLayer = YES;
    }
    return nil;
  }

  // Profile 5 heuristic: full range video
  if (!header->bl_video_full_range_flag) {
    static BOOL loggedOnce = NO;
    if (!loggedOnce) {
      NSLog(@"[FFmpegDecoder] DoVi limited range (Profile 8-like), using "
            @"standard HDR pipeline");
      loggedOnce = YES;
    }
    return nil;
  }

  // Log only once per session to avoid spam
  static BOOL loggedDoViDetection = NO;
  if (!loggedDoViDetection) {
    NSLog(@"[FFmpegDecoder] Processing DoVi Profile 5 metadata");
    loggedDoViDetection = YES;
  }

  const AVDOVIDataMapping *mapping = av_dovi_get_mapping(metadata);
  const AVDOVIColorMetadata *color = av_dovi_get_color(metadata);

  // Extract color matrices (row-major)
  NSMutableArray *nonlinearMatrix = [NSMutableArray arrayWithCapacity:9];
  NSMutableArray *linearMatrix = [NSMutableArray arrayWithCapacity:9];
  NSMutableArray *nonlinearOffset = [NSMutableArray arrayWithCapacity:3];

  for (int i = 0; i < 9; i++) {
    [nonlinearMatrix addObject:@(av_q2d(color->ycc_to_rgb_matrix[i]))];
    [linearMatrix addObject:@(av_q2d(color->rgb_to_lms_matrix[i]))];
  }
  for (int i = 0; i < 3; i++) {
    [nonlinearOffset addObject:@(av_q2d(color->ycc_to_rgb_offset[i]))];
  }

  // Extract reshape curves (per component: I, P, T)
  NSMutableArray *components = [NSMutableArray arrayWithCapacity:3];
  float scale = 1.0f / ((1 << header->bl_bit_depth) - 1);
  float coefScale = 1.0f / (1 << header->coef_log2_denom);

  for (int c = 0; c < 3; c++) {
    const AVDOVIReshapingCurve *curve = &mapping->curves[c];
    NSMutableDictionary *comp = [NSMutableDictionary dictionary];
    comp[@"numPivots"] = @(curve->num_pivots);

    // Pivots normalized to [0, 1]
    NSMutableArray *pivots = [NSMutableArray arrayWithCapacity:9];
    for (int i = 0; i < curve->num_pivots; i++) {
      [pivots addObject:@(scale * curve->pivots[i])];
    }
    comp[@"pivots"] = pivots;

    // Methods and coefficients per interval
    NSMutableArray *methods = [NSMutableArray array];
    NSMutableArray *polyCoeffs = [NSMutableArray array];
    NSMutableArray *mmrOrders = [NSMutableArray array];
    NSMutableArray *mmrConstants = [NSMutableArray array];
    NSMutableArray *mmrCoeffsArray = [NSMutableArray array];

    for (int i = 0; i < curve->num_pivots - 1; i++) {
      [methods addObject:@(curve->mapping_idc[i])];

      if (curve->mapping_idc[i] == AV_DOVI_MAPPING_POLYNOMIAL) {
        NSMutableArray *poly = [NSMutableArray arrayWithCapacity:3];
        for (int k = 0; k < 3; k++) {
          float val = (k <= curve->poly_order[i])
                          ? coefScale * curve->poly_coef[i][k]
                          : 0;
          [poly addObject:@(val)];
        }
        [polyCoeffs addObject:poly];
        [mmrOrders addObject:@(0)];
        [mmrConstants addObject:@(0.0f)];
        [mmrCoeffsArray addObject:@[]];
      } else { // MMR
        [polyCoeffs addObject:@[ @(0.0f), @(0.0f), @(0.0f) ]];
        [mmrOrders addObject:@(curve->mmr_order[i])];
        [mmrConstants addObject:@(coefScale * curve->mmr_constant[i])];

        NSMutableArray *orderCoeffs = [NSMutableArray array];
        for (int j = 0; j < curve->mmr_order[i]; j++) {
          NSMutableArray *coeffs = [NSMutableArray arrayWithCapacity:7];
          for (int k = 0; k < 7; k++) {
            [coeffs addObject:@(coefScale * curve->mmr_coef[i][j][k])];
          }
          [orderCoeffs addObject:coeffs];
        }
        [mmrCoeffsArray addObject:orderCoeffs];
      }
    }

    comp[@"methods"] = methods;
    comp[@"polyCoeffs"] = polyCoeffs;
    comp[@"mmrOrders"] = mmrOrders;
    comp[@"mmrConstants"] = mmrConstants;
    comp[@"mmrCoeffs"] = mmrCoeffsArray;
    [components addObject:comp];
  }

  // Build result dictionary with static metadata
  NSMutableDictionary *result = [NSMutableDictionary dictionaryWithDictionary:@{
    @"nonlinearMatrix" : nonlinearMatrix,
    @"linearMatrix" : linearMatrix,
    @"nonlinearOffset" : nonlinearOffset,
    @"components" : components,
    @"sourceMinPQ" : @(color->source_min_pq / 4095.0f),
    @"sourceMaxPQ" : @(color->source_max_pq / 4095.0f)
  }];

  // Extract L1 scene brightness metadata from extension blocks (per-frame
  // dynamic) L1 contains min_pq, max_pq, avg_pq for the current scene
  for (int i = 0; i < metadata->num_ext_blocks; i++) {
    const AVDOVIDmData *dm = av_dovi_get_ext(metadata, i);
    if (dm->level == 1) {
      // Found L1 block - extract scene brightness
      result[@"sceneMaxPQ"] = @(dm->l1.max_pq / 4095.0f);
      result[@"sceneAvgPQ"] = @(dm->l1.avg_pq / 4095.0f);

      // Log once for verification
      static BOOL loggedL1 = NO;
      if (!loggedL1) {
        NSLog(@"[FFmpegDecoder] DoVi L1 scene brightness: max=%.3f avg=%.3f",
              dm->l1.max_pq / 4095.0f, dm->l1.avg_pq / 4095.0f);
        loggedL1 = YES;
      }
      break;
    }
  }

  return result;
}

- (CVPixelBufferRef)convertFrameToPixelBuffer:(AVFrame *)frame {
  // Output YUV420P directly - Metal shader handles YUV→RGB conversion on GPU
  // This eliminates CPU sws_scale overhead entirely

  CVPixelBufferRef pixelBuffer = NULL;

  // Check if input is already YUV420P (most common software decode output)
  if (frame->format == AV_PIX_FMT_YUV420P) {
    // Use CVPixelBufferPool for efficient buffer reuse
    // This significantly reduces memory fragmentation for high-resolution video

    // Create or recreate pool if dimensions changed
    if (!_i420BufferPool || _poolWidth != frame->width ||
        _poolHeight != frame->height) {
      if (_i420BufferPool) {
        CVPixelBufferPoolRelease(_i420BufferPool);
        _i420BufferPool = NULL;
      }

      NSDictionary *poolAttributes =
          @{(__bridge NSString *)kCVPixelBufferPoolMinimumBufferCountKey : @2};

      NSDictionary *pixelBufferAttributes = @{
        (__bridge NSString *)kCVPixelBufferWidthKey : @(frame->width),
        (__bridge NSString *)kCVPixelBufferHeightKey : @(frame->height),
        (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey :
            @(kCVPixelFormatType_420YpCbCr8Planar),
        (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey : @{}
      };

      CVReturn status = CVPixelBufferPoolCreate(
          kCFAllocatorDefault, (__bridge CFDictionaryRef)poolAttributes,
          (__bridge CFDictionaryRef)pixelBufferAttributes, &_i420BufferPool);

      if (status != kCVReturnSuccess) {
        NSLog(@"[FFmpegDecoder] Failed to create I420 pixel buffer pool");
        return NULL;
      }

      _poolWidth = frame->width;
      _poolHeight = frame->height;
      NSLog(@"[FFmpegDecoder] Created I420 buffer pool: %dx%d", _poolWidth,
            _poolHeight);
    }

    // Get buffer from pool
    CVReturn status =
        CVPixelBufferPoolCreatePixelBuffer(NULL, _i420BufferPool, &pixelBuffer);
    if (status != kCVReturnSuccess) {
      NSLog(@"[FFmpegDecoder] Failed to get buffer from pool: %d", status);
      return NULL;
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, 0);

    // Copy Y plane (full resolution)
    uint8_t *yDest =
        (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0);
    int yDestStride = (int)CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0);
    for (int row = 0; row < frame->height; row++) {
      memcpy(yDest + row * yDestStride,
             frame->data[0] + row * frame->linesize[0], frame->width);
    }

    // Copy U plane (half resolution)
    uint8_t *uDest =
        (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1);
    int uDestStride = (int)CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1);
    int uvHeight = frame->height / 2;
    int uvWidth = frame->width / 2;
    for (int row = 0; row < uvHeight; row++) {
      memcpy(uDest + row * uDestStride,
             frame->data[1] + row * frame->linesize[1], uvWidth);
    }

    // Copy V plane (half resolution)
    uint8_t *vDest =
        (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 2);
    int vDestStride = (int)CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 2);
    for (int row = 0; row < uvHeight; row++) {
      memcpy(vDest + row * vDestStride,
             frame->data[2] + row * frame->linesize[2], uvWidth);
    }

    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    return pixelBuffer;
  }

  // Handle 10-bit YUV420P10LE - output as P010 to preserve HDR data
  // Optimized version using row-wise processing for cache efficiency
  if (frame->format == AV_PIX_FMT_YUV420P10LE) {
    // Use CVPixelBufferPool for efficient P010 buffer reuse
    // This is critical for 4K HDR content to avoid massive memory churn
    // Lazy initialization: only create P010 pool when first HDR frame is
    // detected
    if (!_hasCreatedP010Pool || !_p010BufferPool ||
        _poolWidth != frame->width || _poolHeight != frame->height) {
      if (_p010BufferPool) {
        CVPixelBufferPoolRelease(_p010BufferPool);
        _p010BufferPool = NULL;
      }

      NSDictionary *poolAttributes =
          @{(__bridge NSString *)kCVPixelBufferPoolMinimumBufferCountKey : @2};

      NSDictionary *pixelBufferAttributes = @{
        (__bridge NSString *)kCVPixelBufferWidthKey : @(frame->width),
        (__bridge NSString *)kCVPixelBufferHeightKey : @(frame->height),
        (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey :
            @(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange),
        (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey : @{}
      };

      CVReturn status = CVPixelBufferPoolCreate(
          kCFAllocatorDefault, (__bridge CFDictionaryRef)poolAttributes,
          (__bridge CFDictionaryRef)pixelBufferAttributes, &_p010BufferPool);

      if (status != kCVReturnSuccess) {
        NSLog(@"[FFmpegDecoder] Failed to create P010 pixel buffer pool");
        return NULL;
      }

      _poolWidth = frame->width;
      _poolHeight = frame->height;
      _hasCreatedP010Pool = YES;
      NSLog(@"[FFmpegDecoder] Lazy-created P010 buffer pool: %dx%d", _poolWidth,
            _poolHeight);
    }

    // Get buffer from pool
    CVReturn status =
        CVPixelBufferPoolCreatePixelBuffer(NULL, _p010BufferPool, &pixelBuffer);
    if (status != kCVReturnSuccess) {
      NSLog(@"[FFmpegDecoder] Failed to get P010 buffer from pool: %d", status);
      return NULL;
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, 0);

    // Y plane - optimized row-wise copy with shift
    uint16_t *yDest =
        (uint16_t *)CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0);
    size_t yDestBytesPerRow =
        CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0);
    uint16_t *ySrc = (uint16_t *)frame->data[0];
    int ySrcStride = frame->linesize[0] / 2;

    for (int row = 0; row < frame->height; row++) {
      uint16_t *srcRow = ySrc + row * ySrcStride;
      uint16_t *dstRow =
          (uint16_t *)((uint8_t *)yDest + row * yDestBytesPerRow);
      // Unrolled loop for better performance
      int col = 0;
      int width = frame->width;
      for (; col + 4 <= width; col += 4) {
        dstRow[col] = srcRow[col] << 6;
        dstRow[col + 1] = srcRow[col + 1] << 6;
        dstRow[col + 2] = srcRow[col + 2] << 6;
        dstRow[col + 3] = srcRow[col + 3] << 6;
      }
      for (; col < width; col++) {
        dstRow[col] = srcRow[col] << 6;
      }
    }

    // UV plane - interleave U and V with shift
    uint16_t *uvDest =
        (uint16_t *)CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1);
    size_t uvDestBytesPerRow =
        CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1);
    uint16_t *uSrc = (uint16_t *)frame->data[1];
    uint16_t *vSrc = (uint16_t *)frame->data[2];
    int uSrcStride = frame->linesize[1] / 2;
    int vSrcStride = frame->linesize[2] / 2;
    int uvHeight = frame->height / 2;
    int uvWidth = frame->width / 2;

    for (int row = 0; row < uvHeight; row++) {
      uint16_t *uRow = uSrc + row * uSrcStride;
      uint16_t *vRow = vSrc + row * vSrcStride;
      uint16_t *dstRow =
          (uint16_t *)((uint8_t *)uvDest + row * uvDestBytesPerRow);
      for (int col = 0; col < uvWidth; col++) {
        dstRow[col * 2] = uRow[col] << 6;
        dstRow[col * 2 + 1] = vRow[col] << 6;
      }
    }

    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    return pixelBuffer;
  }

  // For other formats (NV12, YUV422, etc.), use sws_scale to convert to NV12
  // This is a fallback path - most software decoding outputs YUV420P
  if (!_swsContext) {
    _swsContext = sws_getContext(frame->width, frame->height,
                                 (enum AVPixelFormat)frame->format,
                                 frame->width, frame->height, AV_PIX_FMT_NV12,
                                 SWS_BILINEAR, NULL, NULL, NULL);
    if (!_swsContext) {
      NSLog(@"[FFmpegDecoder] Failed to create sws context");
      return NULL;
    }
  }

  NSDictionary *nv12Attributes =
      @{(__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey : @{}};

  CVReturn status = CVPixelBufferCreate(
      kCFAllocatorDefault, frame->width, frame->height,
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, // NV12
      (__bridge CFDictionaryRef)nv12Attributes, &pixelBuffer);

  if (status != kCVReturnSuccess) {
    return NULL;
  }

  CVPixelBufferLockBaseAddress(pixelBuffer, 0);

  uint8_t *yPlane =
      (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0);
  uint8_t *uvPlane =
      (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1);
  int yStride = (int)CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0);
  int uvStride = (int)CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1);

  uint8_t *destData[2] = {yPlane, uvPlane};
  int destLinesize[2] = {yStride, uvStride};

  sws_scale(_swsContext, (const uint8_t *const *)frame->data, frame->linesize,
            0, frame->height, destData, destLinesize);

  CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);

  return pixelBuffer;
}

#pragma mark - Seeking

- (BOOL)seekToTime:(double)seconds accurate:(BOOL)accurate {
  if (!_formatContext || _videoStreamIndex < 0) {
    return NO;
  }

  AVStream *stream = _formatContext->streams[_videoStreamIndex];
  int64_t timestamp = (int64_t)(seconds / av_q2d(stream->time_base));

  // Phase 1: Fast seek to nearest keyframe before target
  // avformat_seek_file allows more precise control than av_seek_frame
  // We use timestamp as max_ts and INT64_MIN as min_ts to enforce backward seek
  // (finding a keyframe <= target)
  if (avformat_seek_file(_formatContext, _videoStreamIndex, INT64_MIN,
                         timestamp, timestamp, AVSEEK_FLAG_BACKWARD) < 0) {
    return NO;
  }

  // Flush codec buffers to reset decoder state
  avcodec_flush_buffers(_codecContext);
  if (_audioCodecContext) {
    avcodec_flush_buffers(_audioCodecContext);
  }

  // If not accurate, stop here (keyframe-only seek for fast scrubbing)
  if (!accurate) {
    return YES;
  }

  // Phase 2: Frame-accurate seek - decode frames until we reach target PTS
  // This is essential for video editing where user wants precise control
  double targetPTS = seconds;
  double tolerance = 0.001; // 1ms tolerance for floating point comparison

  // Optimization: Skip non-reference frames when catching up from far away
  enum AVDiscard originalSkipFrame = _codecContext->skip_frame;
  BOOL optimizationActive = NO;

  if (self.seekOptimizationEnabled) {
    _codecContext->skip_frame = AVDISCARD_NONREF;
    optimizationActive = YES;
  }

  while (true) {
    // Read next packet
    int readResult = av_read_frame(_formatContext, _packet);
    if (readResult < 0) {
      // If we hit EOF or error, we still might have buffered frames in the
      // decoder. Flush it and see if the target is in there.
      if (readResult == AVERROR_EOF) {
        avcodec_send_packet(_codecContext, NULL); // Flush
        while (avcodec_receive_frame(_codecContext, _frame) == 0) {
          if (_frame->pts != AV_NOPTS_VALUE) {
            double framePTS = (double)_frame->pts * av_q2d(stream->time_base);
            if (framePTS >= targetPTS - tolerance) {
              _codecContext->skip_frame = originalSkipFrame;
              return YES;
            }
          }
        }
      }
      av_packet_unref(_packet);
      // Restore skip frame setting before returning
      _codecContext->skip_frame = originalSkipFrame;
      return YES;
    }

    // Only process video packets during seeking
    if (_packet->stream_index == _videoStreamIndex && _codecContext) {

      // Check if we are close enough to target to disable optimization
      // We need to decode all frames accurately when getting close
      if (optimizationActive) {
        double packetPTS = (double)_packet->pts * av_q2d(stream->time_base);
        // Safety margin of 0.5 seconds before target to ensure we have
        // reference frames
        if (packetPTS >= targetPTS - 0.5) {
          _codecContext->skip_frame = originalSkipFrame;
          optimizationActive = NO;
        }
      }

      if (avcodec_send_packet(_codecContext, _packet) < 0) {
        av_packet_unref(_packet);
        continue;
      }

      av_packet_unref(_packet);

      // Drain ALL available frames from the decoder (multi-threaded decoders
      // like dav1d may have multiple frames ready)
      BOOL foundTarget = NO;
      while (true) {
        int ret = avcodec_receive_frame(_codecContext, _frame);

        if (ret == AVERROR(EAGAIN)) {
          // Need more packets before output is available
          break;
        }
        if (ret == AVERROR_EOF || ret < 0) {
          _codecContext->skip_frame = originalSkipFrame; // Restore
          return YES;
        }

        // Check if we've reached the target frame
        if (_frame->pts != AV_NOPTS_VALUE) {
          double framePTS = (double)_frame->pts * av_q2d(stream->time_base);

          // If this frame is at or past our target, we're done
          if (framePTS >= targetPTS - tolerance) {
            foundTarget = YES;
            break;
          }
        }
      }

      if (foundTarget) {
        break; // Exit outer loop to cleanup
      }
    } else {
      // Discard audio and other stream packets during seeking
      av_packet_unref(_packet);
    }
  }

  _codecContext->skip_frame = originalSkipFrame; // Safety restore
  return YES;
}

#pragma mark - Cleanup

- (void)close {
  // Guard against double-close (dealloc also calls close)
  if (!_formatContext && !_codecContext) {
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

  if (_formatContext) {
    avformat_close_input(&_formatContext);
    _formatContext = NULL;
  }

  if (_hwDeviceCtx) {
    av_buffer_unref(&_hwDeviceCtx);
    _hwDeviceCtx = NULL;
  }

  if (_i420BufferPool) {
    // Flush all aged buffers from the pool before releasing
    CVPixelBufferPoolFlush(_i420BufferPool,
                           kCVPixelBufferPoolFlushExcessBuffers);
    CVPixelBufferPoolRelease(_i420BufferPool);
    _i420BufferPool = NULL;
    _poolWidth = 0;
    _poolHeight = 0;
    NSLog(@"[FFmpegDecoder] I420 buffer pool flushed and released");
  }

  if (_p010BufferPool) {
    CVPixelBufferPoolFlush(_p010BufferPool,
                           kCVPixelBufferPoolFlushExcessBuffers);
    CVPixelBufferPoolRelease(_p010BufferPool);
    _p010BufferPool = NULL;
    _hasCreatedP010Pool = NO;
    NSLog(@"[FFmpegDecoder] P010 buffer pool flushed and released");
  }

  _usingHardwareDecoder = NO;
  NSLog(@"[FFmpegDecoder] close() completed - all resources freed");
}

#pragma mark - Cover Image Extraction

- (nullable NSData *)extractCoverImage {
  if (!_formatContext) {
    return nil;
  }

  // Iterate through all streams looking for cover images
  for (unsigned int i = 0; i < _formatContext->nb_streams; i++) {
    AVStream *stream = _formatContext->streams[i];
    enum AVCodecID codecId = stream->codecpar->codec_id;

    // Method 1: Check attachment streams (common in MP4, M4A)
    if (stream->codecpar->codec_type == AVMEDIA_TYPE_ATTACHMENT) {
      // Check if it's an image codec (JPEG, PNG, or BMP)
      if (codecId != AV_CODEC_ID_MJPEG && codecId != AV_CODEC_ID_PNG &&
          codecId != AV_CODEC_ID_BMP) {
        continue;
      }

      // The attachment data is in extradata
      if (stream->codecpar->extradata && stream->codecpar->extradata_size > 0) {
        NSLog(@"[FFmpegDecoder] Found embedded cover image (attachment): %s, "
              @"size: %d bytes",
              avcodec_get_name(codecId), stream->codecpar->extradata_size);
        return [NSData dataWithBytes:stream->codecpar->extradata
                              length:stream->codecpar->extradata_size];
      }
    }

    // Method 2: Check video streams with attached_pic disposition (common in
    // MKV) MKV files store cover images as video streams with the
    // AV_DISPOSITION_ATTACHED_PIC flag
    if (stream->codecpar->codec_type == AVMEDIA_TYPE_VIDEO &&
        (stream->disposition & AV_DISPOSITION_ATTACHED_PIC)) {
      // Verify it's an image codec
      if (codecId != AV_CODEC_ID_MJPEG && codecId != AV_CODEC_ID_PNG &&
          codecId != AV_CODEC_ID_BMP && codecId != AV_CODEC_ID_WEBP) {
        continue;
      }

      // For attached_pic streams, we need to read the packet data
      // The image data is stored as a single packet, not in extradata
      if (stream->attached_pic.data && stream->attached_pic.size > 0) {
        NSLog(@"[FFmpegDecoder] Found embedded cover image (attached_pic): %s, "
              @"size: %d bytes",
              avcodec_get_name(codecId), stream->attached_pic.size);
        return [NSData dataWithBytes:stream->attached_pic.data
                              length:stream->attached_pic.size];
      }
    }
  }

  NSLog(@"[FFmpegDecoder] No embedded cover image found");
  return nil;
}

@end
