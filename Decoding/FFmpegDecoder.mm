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
#import "DoViMetadataExtractor.h"
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
// Pixel format converter for software decode path
@property(nonatomic, strong) PixelFormatConverter *pixelFormatConverter;
// Queue for packets read during seek operations
@property(nonatomic, strong) NSMutableArray<FFmpegPacketData *> *queuedPackets;
@end
#pragma mark - Internal Helper Functions

// Constants for audio conversion
static const int kAudioSampleRate = 48000;
static const enum AVSampleFormat kAudioSampleFormat = AV_SAMPLE_FMT_FLTP;
static const int kAudioChannels = 2; // Stereo

// Constants for seeking
static const double kSeekPTSTolerance = 0.001;       // 1ms for frame matching
static const double kAudioQueueTolerance = 0.05;     // 50ms for audio pre-buffer
static const NSUInteger kMaxQueuedAudioPackets = 500; // Prevent unbounded growth during long seeks
static const double kSeekOptimizationFrameCount = 15.0; // Frames before target to stop skipping

// Error handling helper macro for openVideoFile
// Sets error, calls close, and returns NO in one statement
#define FFMPEG_SET_ERROR_AND_CLOSE(errorPtr, errorCode, errorMsg) \
  do { \
    if (errorPtr) { \
      *errorPtr = [NSError errorWithDomain:@"FFmpegDecoder" \
                                      code:errorCode \
                                  userInfo:@{NSLocalizedDescriptionKey: errorMsg}]; \
    } \
    [self close]; \
    return NO; \
  } while (0)

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
    _pixelFormatConverter = [[PixelFormatConverter alloc] init];
    _queuedPackets = [NSMutableArray array];

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
    return NO; // Don't call close - nothing to clean up yet
  }

  // Retrieve stream information
  if (avformat_find_stream_info(_formatContext, NULL) < 0) {
    FFMPEG_SET_ERROR_AND_CLOSE(error, 1002, @"Failed to find stream information");
  }

  // Find the best video stream
  _videoStreamIndex =
      av_find_best_stream(_formatContext, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
  if (_videoStreamIndex < 0) {
    FFMPEG_SET_ERROR_AND_CLOSE(error, 1003, @"No video stream found");
  }

  AVStream *videoStream = _formatContext->streams[_videoStreamIndex];

  // Find decoder for the video stream
  const AVCodec *codec = avcodec_find_decoder(videoStream->codecpar->codec_id);
  if (!codec) {
    FFMPEG_SET_ERROR_AND_CLOSE(error, 1004, @"Codec not found");
  }

  // Try to initialize hardware decoder
  BOOL hwInitSuccess = [self initHardwareDecoder:codec error:nil];

  // Allocate codec context
  _codecContext = avcodec_alloc_context3(codec);
  if (!_codecContext) {
    FFMPEG_SET_ERROR_AND_CLOSE(error, 1005, @"Failed to allocate codec context");
  }

  // Copy codec parameters to codec context
  if (avcodec_parameters_to_context(_codecContext, videoStream->codecpar) < 0) {
    FFMPEG_SET_ERROR_AND_CLOSE(error, 1006, @"Failed to copy codec parameters");
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
      FFMPEG_SET_ERROR_AND_CLOSE(error, 1007, @"Failed to open codec");
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
    FFMPEG_SET_ERROR_AND_CLOSE(error, 1008, @"Failed to allocate frame or packet");
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
      FFMPEG_SET_ERROR_AND_CLOSE(error, 1009, @"Failed to create scaler context");
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

  // Check if we have queued packets from a seek operation
  if (_queuedPackets.count > 0) {
    FFmpegPacketData *packetData = _queuedPackets.firstObject;
    [_queuedPackets removeObjectAtIndex:0];
    return packetData;
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
      FFmpegPacketData *packetData = [self createPacketDataFromAVPacket:pkt
                                                                isVideo:isVideo
                                                                isAudio:isAudio];
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

  return packetData;
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

    double pts = 0.0;
    if (_frame->pts != AV_NOPTS_VALUE) {
      AVStream *stream = _formatContext->streams[_videoStreamIndex];
      pts = (double)_frame->pts * av_q2d(stream->time_base);
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

  double pts = 0.0;
  if (_frame->pts != AV_NOPTS_VALUE) {
    AVStream *stream = _formatContext->streams[_videoStreamIndex];
    pts = (double)_frame->pts * av_q2d(stream->time_base);
  }

  return [self createVideoFrameFromDecodedFrame:pts];
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
  return [DoViMetadataExtractor extractMetadataFromFrame:frame];
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
  videoFrame.doviMetadata = [self extractDoViMetadataFromFrame:_frame];
  return videoFrame;
}

/// Seeks to the specified time in the video.
///
/// Uses a two-phase strategy:
/// 1. Fast seek to nearest keyframe before target using avformat_seek_file
/// 2. If accurate=YES, decode frames until reaching target PTS
///
/// When seek optimization is enabled, non-reference frames are skipped during
/// the catch-up phase (from keyframe to ~15 frames before target) for better performance.
///
/// @param seconds Target time in seconds
/// @param accurate If YES, decode frames for precise positioning; if NO, return nearest keyframe
/// @return The frame at or after the target time, or nil on failure
- (nullable FFmpegVideoFrame *)seekToTime:(double)seconds accurate:(BOOL)accurate {
  if (!_formatContext || _videoStreamIndex < 0) {
    return nil;
  }

  // Clear any previously queued packets
  [_queuedPackets removeAllObjects];

  AVStream *stream = _formatContext->streams[_videoStreamIndex];
  int64_t timestamp = (int64_t)(seconds / av_q2d(stream->time_base));

  // Phase 1: Fast seek to nearest keyframe before target
  if (avformat_seek_file(_formatContext, _videoStreamIndex, INT64_MIN,
                         timestamp, timestamp, AVSEEK_FLAG_BACKWARD) < 0) {
    return nil;
  }

  // Flush codec buffers to reset decoder state
  avcodec_flush_buffers(_codecContext);
  if (_audioCodecContext) {
    avcodec_flush_buffers(_audioCodecContext);
  }

  // Phase 2: Frame-accurate seek - decode frames until we reach target PTS
  double targetPTS = seconds;

  // Optimization: Skip non-reference frames when catching up from far away
  enum AVDiscard originalSkipFrame = _codecContext->skip_frame;
  BOOL optimizationActive = NO;
  // Calculate adaptive threshold: ~15 frames before target, proportional to frame rate
  double adaptiveThreshold = kSeekOptimizationFrameCount / _videoInfo.frameRate;

  if (accurate && self.seekOptimizationEnabled) {
    _codecContext->skip_frame = AVDISCARD_NONREF;
    optimizationActive = YES;
  }

  FFmpegVideoFrame *resultFrame = nil;

  while (true) {
    int readResult = av_read_frame(_formatContext, _packet);
    if (readResult < 0) {
      // Handle EOF or error
      if (readResult == AVERROR_EOF) {
        int flushRet = avcodec_send_packet(_codecContext, NULL); // Flush
        if (flushRet < 0 && flushRet != AVERROR_EOF) {
          NSLog(@"[FFmpegDecoder] Warning: flush packet failed: %s", av_err2str(flushRet));
        }
        while (avcodec_receive_frame(_codecContext, _frame) == 0) {
          double framePTS = 0.0;
          if (_frame->pts != AV_NOPTS_VALUE) {
            framePTS = (double)_frame->pts * av_q2d(stream->time_base);
          }
          
          if (!accurate || framePTS >= targetPTS - kSeekPTSTolerance) {
            resultFrame = [self createVideoFrameFromDecodedFrame:framePTS];
            break;
          }
        }
      }
      av_packet_unref(_packet);
      break;
    }

    // Audio Packet - Queue it for later consumption (only during accurate seeks)
    if (_packet->stream_index == _audioStreamIndex && _audioCodecContext && accurate) {
      AVStream *audioStream = _formatContext->streams[_audioStreamIndex];
      double audioPTS = (double)_packet->pts * av_q2d(audioStream->time_base);
      
      // Only queue audio packets that are close to or after our target time
      // Discard packets from the "catch-up" phase (between keyframe and target)
      // Use a small negative tolerance to ensure we don't miss the start of the audio segment
      if (audioPTS >= targetPTS - kAudioQueueTolerance && _queuedPackets.count < kMaxQueuedAudioPackets) {
          FFmpegPacketData *packetData = [self createPacketDataFromAVPacket:_packet
                                                                    isVideo:NO
                                                                    isAudio:YES];
          [_queuedPackets addObject:packetData];
      }
      av_packet_unref(_packet);
      continue;
    }

    // Video Packet - Decode
    if (_packet->stream_index == _videoStreamIndex && _codecContext) {
      if (optimizationActive) {
        double packetPTS = (double)_packet->pts * av_q2d(stream->time_base);
        if (packetPTS >= targetPTS - adaptiveThreshold) {
          _codecContext->skip_frame = originalSkipFrame;
          optimizationActive = NO;
        }
      }

      if (avcodec_send_packet(_codecContext, _packet) < 0) {
        av_packet_unref(_packet);
        continue;
      }

      av_packet_unref(_packet);

      // Drain frames
      while (true) {
        int ret = avcodec_receive_frame(_codecContext, _frame);
        if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF || ret < 0) break;

        double framePTS = 0.0;
        if (_frame->pts != AV_NOPTS_VALUE) {
          framePTS = (double)_frame->pts * av_q2d(stream->time_base);
        }

        // If not accurate, return the first frame we find (keyframe)
        // If accurate, wait for target
        if (!accurate || framePTS >= targetPTS - kSeekPTSTolerance) {
          resultFrame = [self createVideoFrameFromDecodedFrame:framePTS];
          break; // Found it
        }
      }

      if (resultFrame) {
        break; // Exit outer loop
      }
    } else {
      // Discard other stream packets
      av_packet_unref(_packet);
    }
  }

  _codecContext->skip_frame = originalSkipFrame; // Safety restore
  return resultFrame;
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

  // Cleanup pixel format converter (handles I420 and P010 buffer pools)
  [_pixelFormatConverter cleanup];
  _pixelFormatConverter = nil;

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
