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
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <stdatomic.h>
#import <time.h>

#pragma mark - Data Structure Implementations

@implementation FFmpegDemuxerVideoInfo

- (BOOL)isHDR {
  // AVCOL_TRC_SMPTE2084 = 16 (PQ/HDR10)
  // AVCOL_TRC_ARIB_STD_B67 = 18 (HLG)
  return _colorTransfer == 16 || _colorTransfer == 18;
}

@end

@implementation FFmpegAudioTrackInfo
@end

@implementation FFmpegSubtitleTrackInfo
@end

@interface FFmpegDemuxerPacket ()
- (void)setBackingPacket:(AVPacket *)packet;
@end

static void ReleasePacketBackedBlockMemory(
    void *refCon, void *doomedMemoryBlock, size_t sizeInBytes) {
  (void)doomedMemoryBlock;
  (void)sizeInBytes;
  if (refCon) {
    CFRelease((CFTypeRef)refCon);
  }
}

@implementation FFmpegDemuxerPacket {
  AVPacket *_backingPacket;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _backingPacket = NULL;
  }
  return self;
}

- (void)dealloc {
  if (_backingPacket) {
    av_packet_free(&_backingPacket);
    _backingPacket = NULL;
  }
}

- (void)setBackingPacket:(AVPacket *)packet {
  if (_backingPacket) {
    av_packet_free(&_backingPacket);
    _backingPacket = NULL;
  }
  _backingPacket = packet;
}

- (nullable CMBlockBufferRef)createCMBlockBuffer {
  if (!_backingPacket || !_backingPacket->data || _backingPacket->size <= 0) {
    return nil;
  }

  CMBlockBufferCustomBlockSource blockSource = {
      .version = kCMBlockBufferCustomBlockSourceVersion,
      .AllocateBlock = NULL,
      .FreeBlock = ReleasePacketBackedBlockMemory,
      .refCon = (void *)CFBridgingRetain(self),
  };

  CMBlockBufferRef blockBuffer = NULL;
  OSStatus status = CMBlockBufferCreateWithMemoryBlock(
      kCFAllocatorDefault, _backingPacket->data, _backingPacket->size,
      kCFAllocatorNull, &blockSource, 0, _backingPacket->size, 0, &blockBuffer);
  if (status != noErr || !blockBuffer) {
    CFRelease(blockSource.refCon);
    return nil;
  }

  return blockBuffer;
}

- (BOOL)copyToAVPacket:(void *)outPacket {
  if (!outPacket) {
    return NO;
  }

  AVPacket *dst = (AVPacket *)outPacket;
  av_packet_unref(dst);

  if (_backingPacket) {
    return av_packet_ref(dst, _backingPacket) == 0;
  }

  // Fallback for packets without retained backing storage.
  if (self.size > 0 && self.data.length > 0) {
    if (av_new_packet(dst, (int)self.size) < 0) {
      return NO;
    }
    memcpy(dst->data, self.data.bytes, (size_t)self.size);
  }

  dst->pts = self.pts;
  dst->dts = self.dts;
  dst->duration = self.duration;
  dst->flags = self.isKeyframe ? AV_PKT_FLAG_KEY : 0;
  return YES;
}
@end

#pragma mark - Private Interface

@interface FFmpegDemuxer ()
@property(nonatomic, assign) AVFormatContext *formatContext;
@property(nonatomic, assign) AVPacket *packet;
@property(nonatomic, assign) int videoStreamIndex;
@property(nonatomic, assign) int audioStreamIndex;
@property(nonatomic, strong) NSMutableArray<NSNumber *> *audioStreamIndices;
@property(nonatomic, assign) int subtitleStreamIndex;
@property(nonatomic, strong) NSMutableArray<NSNumber *> *subtitleStreamIndices;

@property(nonatomic, copy) NSString *filePath;

@property(nonatomic, strong) FFmpegDemuxerVideoInfo *videoInfo;
@property(nonatomic, strong)
    NSMutableArray<FFmpegDemuxerPacket *> *queuedAudioPackets;

- (void)ensureExtradata;
@end

#pragma mark - Constants

// For seeking audio queue management
static const double kAudioQueueTolerance = 0.05; // 50ms for audio pre-buffer
static const NSUInteger kMaxQueuedAudioPackets =
    500; // Prevent unbounded growth

// Error helper macro
#define DEMUXER_SET_ERROR_AND_CLOSE(errorPtr, errorCode, errorMsg)             \
  do {                                                                         \
    if (errorPtr) {                                                            \
      *errorPtr =                                                              \
          [NSError errorWithDomain:@"FFmpegDemuxer"                            \
                              code:errorCode                                   \
                          userInfo:@{NSLocalizedDescriptionKey : errorMsg}];   \
    }                                                                          \
    [self close];                                                              \
    return NO;                                                                 \
  } while (0)

#pragma mark - Implementation

@implementation FFmpegDemuxer {
  atomic_bool _abortRequested;
}

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
    _queuedAudioPackets = [NSMutableArray array];
    _subtitleStreamIndex = -1;
    _subtitleStreamIndices = [NSMutableArray array];
    atomic_init(&_abortRequested, false);

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
  _filePath = [url path];
  const char *filename = [_filePath UTF8String];

  _formatContext = avformat_alloc_context();
  if (!_formatContext) {
    if (error) {
      *error = [NSError errorWithDomain:@"FFmpegDemuxer"
                                   code:1000
                               userInfo:@{
                                 NSLocalizedDescriptionKey :
                                     @"Failed to allocate format context"
                               }];
    }
    return NO;
  }

  _formatContext->interrupt_callback.opaque = (__bridge void *)self;
  _formatContext->interrupt_callback.callback = [](void *opaque) -> int {
    FFmpegDemuxer *demuxer = (__bridge FFmpegDemuxer *)opaque;
    if (!demuxer) {
      return 0;
    }
    return atomic_load_explicit(&demuxer->_abortRequested, memory_order_relaxed)
               ? 1
               : 0;
  };

  // Open input file
  if (avformat_open_input(&_formatContext, filename, NULL, NULL) < 0) {
    if (error) {
      *error = [NSError
          errorWithDomain:@"FFmpegDemuxer"
                     code:1001
                 userInfo:@{
                   NSLocalizedDescriptionKey : @"Failed to open video file"
                 }];
    }
    if (_formatContext) {
      avformat_free_context(_formatContext);
      _formatContext = NULL;
    }
    return NO;
  }

  // Retrieve stream information
  if (avformat_find_stream_info(_formatContext, NULL) < 0) {
    DEMUXER_SET_ERROR_AND_CLOSE(error, 1002,
                                @"Failed to find stream information");
  }

  // Find the best video stream
  _videoStreamIndex =
      av_find_best_stream(_formatContext, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);

  // Find all audio streams and identify default
  _audioStreamIndices = [NSMutableArray array];
  int defaultAudioStream = -1;
  for (unsigned int i = 0; i < _formatContext->nb_streams; i++) {
    if (_formatContext->streams[i]->codecpar->codec_type ==
        AVMEDIA_TYPE_AUDIO) {
      [_audioStreamIndices addObject:@(i)];
      // Check if this is the default audio stream
      if (_formatContext->streams[i]->disposition & AV_DISPOSITION_DEFAULT) {
        defaultAudioStream = i;
      }
    }
  }

  if (_videoStreamIndex < 0 && _audioStreamIndices.count == 0) {
    DEMUXER_SET_ERROR_AND_CLOSE(error, 1003, @"No video or audio stream found");
  }
  // Select default audio stream, or first if no default specified
  if (defaultAudioStream >= 0) {
    _audioStreamIndex = defaultAudioStream;
  } else if (_audioStreamIndices.count > 0) {
    _audioStreamIndex = [_audioStreamIndices[0] intValue];
  } else {
    _audioStreamIndex = -1;
  }

  // Find all subtitle streams and identify default
  _subtitleStreamIndices = [NSMutableArray array];
  int defaultSubtitleStream = -1;
  for (unsigned int i = 0; i < _formatContext->nb_streams; i++) {
    if (_formatContext->streams[i]->codecpar->codec_type ==
        AVMEDIA_TYPE_SUBTITLE) {
      [_subtitleStreamIndices addObject:@(i)];
      if (_formatContext->streams[i]->disposition & AV_DISPOSITION_DEFAULT) {
        defaultSubtitleStream = i;
      }
    }
  }

  if (defaultSubtitleStream >= 0) {
    _subtitleStreamIndex = defaultSubtitleStream;
  } else if (_subtitleStreamIndices.count > 0) {
    // We generally don't auto-select subtitles unless forced/default
    _subtitleStreamIndex = -1;
  } else {
    _subtitleStreamIndex = -1;
  }

  // Allocate packet for demuxing
  _packet = av_packet_alloc();
  if (!_packet) {
    DEMUXER_SET_ERROR_AND_CLOSE(error, 1004, @"Failed to allocate packet");
  }

  // Build video info
  [self ensureExtradata];
  [self buildVideoInfo];

  return YES;
}

#pragma mark - I/O Control

- (void)requestAbortIO {
  atomic_store_explicit(&_abortRequested, true, memory_order_relaxed);
}

- (void)clearAbortIO {
  atomic_store_explicit(&_abortRequested, false, memory_order_relaxed);
}

- (void)ensureExtradata {
  if (!_formatContext || _videoStreamIndex < 0)
    return;

  AVCodecParameters *codecPar =
      _formatContext->streams[_videoStreamIndex]->codecpar;

  // Check if HEVC and extradata is missing or suspicious (header only, no
  // arrays)
  BOOL isHEVC = (codecPar->codec_id == AV_CODEC_ID_HEVC);

  // HEVC decoder config record header is 23 bytes. If size <= 23, it typically
  // has no NAL arrays.
  BOOL needsExtradata = NO;
  if (codecPar->extradata_size == 0) {
    needsExtradata = YES;
  } else if (isHEVC && codecPar->extradata_size <= 23) {
    needsExtradata = YES;
  }

  if (!needsExtradata)
    return;

  // Use hevc_mp4toannexb to ensure we have standard Annex B start codes
  const AVBitStreamFilter *filter = av_bsf_get_by_name("hevc_mp4toannexb");
  if (!filter) {
    return;
  }

  __block AVBSFContext *bsfCtx = NULL;
  __block AVPacket *pkt = NULL;
  __block AVPacket *pktOut = NULL;

  // Helper to free resources
  void (^cleanup)(void) = ^{
    if (bsfCtx)
      av_bsf_free(&bsfCtx);
    if (pkt)
      av_packet_free(&pkt);
    if (pktOut)
      av_packet_free(&pktOut);
  };

  if (av_bsf_alloc(filter, &bsfCtx) < 0 ||
      avcodec_parameters_copy(bsfCtx->par_in, codecPar) < 0 ||
      av_bsf_init(bsfCtx) < 0) {
    cleanup();
    return;
  }

  pkt = av_packet_alloc();
  pktOut = av_packet_alloc();
  if (!pkt || !pktOut) {
    cleanup();
    return;
  }

  // Store found NALs
  __block NSMutableData *vpsData = nil;
  __block NSMutableData *spsData = nil;
  __block NSMutableData *ppsData = nil;

  int packetsChecked = 0;
  const int MaxPacketsToCheck = 2000;

  // Seek to start
  if (av_seek_frame(_formatContext, _videoStreamIndex, 0,
                    AVSEEK_FLAG_BACKWARD) < 0) {
    cleanup();
    return;
  }

  BOOL foundAll = NO;

  while (packetsChecked < MaxPacketsToCheck) {
    int ret = av_read_frame(_formatContext, pkt);
    if (ret < 0)
      break;

    if (pkt->stream_index == _videoStreamIndex) {
      ret = av_bsf_send_packet(bsfCtx, pkt);
      if (ret < 0) {
        av_packet_unref(pkt);
        break;
      }

      while (ret >= 0) {
        ret = av_bsf_receive_packet(bsfCtx, pktOut);
        if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF)
          break;
        if (ret < 0)
          break;

        // Parse NAL units from pktOut->data (Annex B)
        uint8_t *data = pktOut->data;
        int size = pktOut->size;

        int i = 0;
        while (i < size - 4) {
          // Find start code 00 00 01 or 00 00 00 01
          if (data[i] == 0 && data[i + 1] == 0) {
            int startCodeLen = 0;
            if (data[i + 2] == 1) {
              startCodeLen = 3;
            } else if (data[i + 2] == 0 && data[i + 3] == 1) {
              startCodeLen = 4;
            }

            if (startCodeLen > 0) {
              // NAL Header
              uint8_t nalHeader = data[i + startCodeLen];
              int nalType = (nalHeader & 0x7E) >> 1;

              // Find next start code or end
              int nextStart = i + startCodeLen + 1;
              while (nextStart < size - 3) {
                if (data[nextStart] == 0 && data[nextStart + 1] == 0 &&
                    (data[nextStart + 2] == 1 ||
                     (data[nextStart + 2] == 0 && data[nextStart + 3] == 1))) {
                  break;
                }
                nextStart++;
              }
              if (nextStart >= size - 3)
                nextStart = size;

              int nalSize = nextStart - (i + startCodeLen);
              NSData *nalData = [NSData dataWithBytes:&data[i + startCodeLen]
                                               length:nalSize];

              if (nalType == 32) { // VPS
                if (!vpsData)
                  vpsData = [nalData mutableCopy];
              } else if (nalType == 33) { // SPS
                if (!spsData)
                  spsData = [nalData mutableCopy];
              } else if (nalType == 34) { // PPS
                if (!ppsData)
                  ppsData = [nalData mutableCopy];
              }

              i = nextStart;
              continue;
            }
          }
          i++;
        }

        if (vpsData && spsData && ppsData) {
          foundAll = YES;
          break;
        }

        av_packet_unref(pktOut);
      }
    }

    av_packet_unref(pkt);
    if (foundAll)
      break;
    packetsChecked++;
  }

  if (foundAll) {
    // Prepare parameter sets for CoreMedia
    const uint8_t *parameterSetPointers[3] = {(const uint8_t *)vpsData.bytes,
                                              (const uint8_t *)spsData.bytes,
                                              (const uint8_t *)ppsData.bytes};

    size_t parameterSetSizes[3] = {vpsData.length, spsData.length,
                                   ppsData.length};

    CMFormatDescriptionRef formatDescription = NULL;
    OSStatus status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
        kCFAllocatorDefault,
        3, // parameterSetCount
        parameterSetPointers, parameterSetSizes,
        4,    // NALUnitHeaderLength (standard for MP4/AVC/HEVC)
        NULL, // extensions
        &formatDescription);

    if (status == noErr && formatDescription) {
      // Retrieve the 'hvcC' atom from the format description
      CFDictionaryRef atoms = (CFDictionaryRef)CMFormatDescriptionGetExtension(
          formatDescription,
          kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms);

      NSData *hvcCData = nil;
      if (atoms) {
        hvcCData = (NSData *)CFDictionaryGetValue(atoms, CFSTR("hvcC"));
      }

      if (hvcCData && hvcCData.length > 0) {
        // Update codecPar
        if (codecPar->extradata) {
          av_free(codecPar->extradata);
        }

        codecPar->extradata_size = (int)hvcCData.length;
        codecPar->extradata = (uint8_t *)av_malloc(
            codecPar->extradata_size + AV_INPUT_BUFFER_PADDING_SIZE);

        memcpy(codecPar->extradata, hvcCData.bytes, hvcCData.length);
        memset(codecPar->extradata + codecPar->extradata_size, 0,
               AV_INPUT_BUFFER_PADDING_SIZE);

        // Mark as synthesized
        _didSynthesizeExtradata = YES;
      }

      CFRelease(formatDescription);
    }
  }

  cleanup();

  // Seek back
  if (av_seek_frame(_formatContext, _videoStreamIndex, 0,
                    AVSEEK_FLAG_BACKWARD) < 0) {
  }
}

- (void)buildVideoInfo {
  _videoInfo = [[FFmpegDemuxerVideoInfo alloc] init];

  if (_videoStreamIndex >= 0) {
    AVStream *videoStream = _formatContext->streams[_videoStreamIndex];
    AVCodecParameters *codecPars = videoStream->codecpar;
    const AVCodec *codec = avcodec_find_decoder(codecPars->codec_id);

    _videoInfo.width = codecPars->width;
    _videoInfo.height = codecPars->height;
    _videoInfo.codecName =
        codec ? [NSString stringWithUTF8String:codec->name] : @"unknown";

    // Color metadata (prefer codec params, fallback to stream)
    _videoInfo.colorPrimaries = codecPars->color_primaries;
    _videoInfo.colorTransfer = codecPars->color_trc;
    _videoInfo.colorSpace = codecPars->color_space;
    _videoInfo.colorRange = codecPars->color_range;

    // Check for Dolby Vision
    const AVPacketSideData *doviSideData = av_packet_side_data_get(
        codecPars->coded_side_data, codecPars->nb_coded_side_data,
        AV_PKT_DATA_DOVI_CONF);
    if (doviSideData &&
        doviSideData->size >= sizeof(AVDOVIDecoderConfigurationRecord)) {
      _videoInfo.isDolbyVision = YES;
      const AVDOVIDecoderConfigurationRecord *doviConf =
          (const AVDOVIDecoderConfigurationRecord *)doviSideData->data;
      _videoInfo.doviProfile = doviConf->dv_profile;
    }

    // Content Light Level
    const AVPacketSideData *cllSideData = av_packet_side_data_get(
        codecPars->coded_side_data, codecPars->nb_coded_side_data,
        AV_PKT_DATA_CONTENT_LIGHT_LEVEL);
    if (cllSideData && cllSideData->size >= sizeof(AVContentLightMetadata)) {
      const AVContentLightMetadata *cll =
          (const AVContentLightMetadata *)cllSideData->data;
      _videoInfo.maxContentLightLevel = cll->MaxCLL;
      _videoInfo.maxFrameAverageLightLevel = cll->MaxFALL;
    }

    // Mastering Display Metadata
    const AVPacketSideData *mdSideData = av_packet_side_data_get(
        codecPars->coded_side_data, codecPars->nb_coded_side_data,
        AV_PKT_DATA_MASTERING_DISPLAY_METADATA);
    if (mdSideData && mdSideData->size >= sizeof(AVMasteringDisplayMetadata)) {
      const AVMasteringDisplayMetadata *md =
          (const AVMasteringDisplayMetadata *)mdSideData->data;
      if (md->has_luminance) {
        _videoInfo.masteringDisplayMaxLuminance =
            (double)av_q2d(md->max_luminance);
        _videoInfo.masteringDisplayMinLuminance =
            (double)av_q2d(md->min_luminance);
      }
    }

    // Bits per component
    const AVPixFmtDescriptor *pixFmtDesc =
        av_pix_fmt_desc_get((enum AVPixelFormat)codecPars->format);
    _videoInfo.bitsPerComponent = pixFmtDesc ? pixFmtDesc->comp[0].depth : 8;

    // Frame rate
    AVRational frameRate =
        av_guess_frame_rate(_formatContext, videoStream, NULL);
    if (frameRate.num && frameRate.den) {
      _videoInfo.frameRate = (double)frameRate.num / (double)frameRate.den;
    } else {
      _videoInfo.frameRate = 30.0;
    }

    // Duration
    if (videoStream->duration != AV_NOPTS_VALUE) {
      _videoInfo.duration =
          (double)videoStream->duration * av_q2d(videoStream->time_base);
    }

    // Sample Aspect Ratio
    AVRational sar = videoStream->sample_aspect_ratio;
    if (sar.num == 0 || sar.den == 0) {
      sar = codecPars->sample_aspect_ratio;
    }
    _videoInfo.sampleAspectRatioNum = sar.num;
    _videoInfo.sampleAspectRatioDen = sar.den;
  } else {
    _videoInfo.width = 0;
    _videoInfo.height = 0;
    _videoInfo.codecName = @"none";
    _videoInfo.frameRate = 0;
    _videoInfo.duration = 0;
  }

  // Container format
  if (_formatContext->iformat) {
    const char *name = _formatContext->iformat->long_name
                           ? _formatContext->iformat->long_name
                           : _formatContext->iformat->name;
    _videoInfo.formatName = [NSString stringWithUTF8String:name];
  } else {
    _videoInfo.formatName = @"Unknown";
  }

  // Use container duration if video duration is missing or zero
  if (_videoInfo.duration <= 0 && _formatContext->duration != AV_NOPTS_VALUE) {
    _videoInfo.duration = (double)_formatContext->duration / AV_TIME_BASE;
  }

  // Audio info
  if (_audioStreamIndex >= 0) {
    AVStream *audioStream = _formatContext->streams[_audioStreamIndex];
    const AVCodec *audioCodec =
        avcodec_find_decoder(audioStream->codecpar->codec_id);
    if (audioCodec) {
      _videoInfo.audioCodecName =
          [NSString stringWithUTF8String:audioCodec->name];
    }
    _videoInfo.audioSampleRate = audioStream->codecpar->sample_rate;
    _videoInfo.audioSampleRate = audioStream->codecpar->sample_rate;
    _videoInfo.audioChannels = audioStream->codecpar->ch_layout.nb_channels;
  }
}

#pragma mark - Metadata

- (nullable FFmpegDemuxerVideoInfo *)getVideoInfo {
  return _videoInfo;
}

- (BOOL)supportsHardwareDecode {
  if (!_formatContext || _videoStreamIndex < 0)
    return NO;
  AVCodecParameters *codecPars =
      _formatContext->streams[_videoStreamIndex]->codecpar;
  return codecPars->codec_id == AV_CODEC_ID_HEVC ||
         codecPars->codec_id == AV_CODEC_ID_H264;
}

- (int)videoCodecId {
  if (!_formatContext || _videoStreamIndex < 0)
    return 0;
  return _formatContext->streams[_videoStreamIndex]->codecpar->codec_id;
}

- (int32_t)timeBaseNum {
  if (!_formatContext || _videoStreamIndex < 0)
    return 1;
  return _formatContext->streams[_videoStreamIndex]->time_base.num;
}

- (int32_t)timeBaseDen {
  if (!_formatContext || _videoStreamIndex < 0)
    return 1;
  return _formatContext->streams[_videoStreamIndex]->time_base.den;
}

- (nullable NSDictionary<NSString *, id> *)getSampleBufferBuilderConfig {
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

  // HEVC extradata must be valid (header is 23 bytes, need > 23 for arrays)
  if (codecPars->codec_id == AV_CODEC_ID_HEVC &&
      codecPars->extradata_size <= 23) {
    return nil;
  }

  NSData *extradata = [NSData dataWithBytes:codecPars->extradata
                                     length:codecPars->extradata_size];

  // Dolby Vision config
  NSData *dolbyVisionConfig = nil;
  const AVPacketSideData *doviSideData = av_packet_side_data_get(
      codecPars->coded_side_data, codecPars->nb_coded_side_data,
      AV_PKT_DATA_DOVI_CONF);
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
  config[@"sampleAspectRatioNum"] = @(_videoInfo.sampleAspectRatioNum);
  config[@"sampleAspectRatioDen"] = @(_videoInfo.sampleAspectRatioDen);

  if (dolbyVisionConfig) {
    config[@"dolbyVisionConfig"] = dolbyVisionConfig;
  }

  return config;
}

- (nullable NSDictionary<NSString *, id> *)getDecoderConfig {
  if (!_formatContext) {
    return nil;
  }

  NSMutableDictionary *config = [NSMutableDictionary dictionary];

  if (_videoStreamIndex >= 0) {
    AVStream *videoStream = _formatContext->streams[_videoStreamIndex];
    AVCodecParameters *codecPars = videoStream->codecpar;

    // Video codec info
    config[@"videoCodecId"] = @(codecPars->codec_id);
    config[@"width"] = @(codecPars->width);
    config[@"height"] = @(codecPars->height);
    config[@"pixelFormat"] = @(codecPars->format);
    config[@"videoTimeBaseNum"] = @(videoStream->time_base.num);
    config[@"videoTimeBaseDen"] = @(videoStream->time_base.den);

    // Video extradata
    if (codecPars->extradata && codecPars->extradata_size > 0) {
      config[@"videoExtradata"] =
          [NSData dataWithBytes:codecPars->extradata
                         length:codecPars->extradata_size];
    }

    // Color metadata
    config[@"colorPrimaries"] = @(codecPars->color_primaries);
    config[@"colorTransfer"] = @(codecPars->color_trc);
    config[@"colorSpace"] = @(codecPars->color_space);
    config[@"colorRange"] = @(codecPars->color_range);
    config[@"sampleAspectRatioNum"] = @(_videoInfo.sampleAspectRatioNum);
    config[@"sampleAspectRatioDen"] = @(_videoInfo.sampleAspectRatioDen);

    // Dolby Vision config
    const AVPacketSideData *doviSideData = av_packet_side_data_get(
        codecPars->coded_side_data, codecPars->nb_coded_side_data,
        AV_PKT_DATA_DOVI_CONF);
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

    // Frame rate
    AVRational frameRate =
        av_guess_frame_rate(_formatContext, videoStream, NULL);
    if (frameRate.num && frameRate.den) {
      config[@"frameRate"] = @((double)frameRate.num / (double)frameRate.den);
    }

    // Video Duration
    if (videoStream->duration != AV_NOPTS_VALUE) {
      config[@"duration"] =
          @((double)videoStream->duration * av_q2d(videoStream->time_base));
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
      config[@"audioExtradata"] =
          [NSData dataWithBytes:audioPars->extradata
                         length:audioPars->extradata_size];
    }
  }

  // Subtitle codec info (if present)
  if (_subtitleStreamIndex >= 0) {
    AVStream *subStream = _formatContext->streams[_subtitleStreamIndex];
    AVCodecParameters *subPars = subStream->codecpar;

    config[@"subtitleCodecId"] = @(subPars->codec_id);
    config[@"subtitleStreamIndex"] = @(_subtitleStreamIndex);
    config[@"subtitleTimeBaseNum"] = @(subStream->time_base.num);
    config[@"subtitleTimeBaseDen"] = @(subStream->time_base.den);

    if (subPars->extradata && subPars->extradata_size > 0) {
      config[@"subtitleExtradata"] =
          [NSData dataWithBytes:subPars->extradata
                         length:subPars->extradata_size];
    }
  }

  // Fallback duration if missing from video/audio specific info
  if (!config[@"duration"] && _formatContext->duration != AV_NOPTS_VALUE) {
    config[@"duration"] = @((double)_formatContext->duration / AV_TIME_BASE);
  }

  return config;
}

- (nullable NSDictionary<NSString *, id> *)getAudioDecoderConfigForStream:
    (int)streamIndex {
  // Verify the format context exists
  if (!_formatContext) {
    return nil;
  }

  // Verify the stream index is valid
  if (streamIndex < 0 ||
      (unsigned int)streamIndex >= _formatContext->nb_streams) {
    return nil;
  }

  AVStream *stream = _formatContext->streams[streamIndex];
  AVCodecParameters *codecPars = stream->codecpar;

  // Verify it's an audio stream
  if (codecPars->codec_type != AVMEDIA_TYPE_AUDIO) {
    return nil;
  }

  NSMutableDictionary *config = [NSMutableDictionary dictionary];

  // Audio codec info
  config[@"audioCodecId"] = @(codecPars->codec_id);
  config[@"audioSampleRate"] = @(codecPars->sample_rate);
  config[@"audioChannels"] = @(codecPars->ch_layout.nb_channels);
  config[@"audioTimeBaseNum"] = @(stream->time_base.num);
  config[@"audioTimeBaseDen"] = @(stream->time_base.den);
  config[@"audioStreamIndex"] = @(streamIndex);

  // Audio extradata
  if (codecPars->extradata && codecPars->extradata_size > 0) {
    config[@"audioExtradata"] =
        [NSData dataWithBytes:codecPars->extradata
                       length:codecPars->extradata_size];
  }

  return config;
}

- (nullable NSDictionary<NSString *, id> *)getSubtitleDecoderConfigForStream:
    (int)streamIndex {
  if (!_formatContext) {
    return nil;
  }

  if (streamIndex < 0 ||
      (unsigned int)streamIndex >= _formatContext->nb_streams) {
    return nil;
  }

  AVStream *stream = _formatContext->streams[streamIndex];
  AVCodecParameters *codecPars = stream->codecpar;

  if (codecPars->codec_type != AVMEDIA_TYPE_SUBTITLE) {
    return nil;
  }

  NSMutableDictionary *config = [NSMutableDictionary dictionary];

  config[@"subtitleCodecId"] = @(codecPars->codec_id);
  config[@"subtitleStreamIndex"] = @(streamIndex);
  config[@"subtitleTimeBaseNum"] = @(stream->time_base.num);
  config[@"subtitleTimeBaseDen"] = @(stream->time_base.den);

  if (codecPars->extradata && codecPars->extradata_size > 0) {
    config[@"subtitleExtradata"] =
        [NSData dataWithBytes:codecPars->extradata
                       length:codecPars->extradata_size];
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
    BOOL isAudio =
        (_packet->stream_index == _audioStreamIndex && _audioStreamIndex >= 0);
    BOOL isSubtitle = (_packet->stream_index == _subtitleStreamIndex &&
                       _subtitleStreamIndex >= 0);
    if (isVideo || isAudio || isSubtitle) {
      FFmpegDemuxerPacket *packet = [self createPacketFromAV:_packet
                                                     isVideo:isVideo
                                                     isAudio:isAudio
                                                  isSubtitle:isSubtitle];

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

  // Use pure FFmpeg seeking without custom index
  int64_t timestamp = (int64_t)(seconds / av_q2d(stream->time_base));

  if (avformat_seek_file(_formatContext, _videoStreamIndex, INT64_MIN,
                         timestamp, timestamp, AVSEEK_FLAG_BACKWARD) < 0) {
    return NO;
  }

  return YES;
}

- (nullable NSArray<FFmpegDemuxerPacket *> *)collectPacketsUntil:
    (double)targetPTS {
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
        FFmpegDemuxerPacket *pkt = [self createPacketFromAV:_packet
                                                    isVideo:NO
                                                    isAudio:YES
                                                 isSubtitle:NO];
        [_queuedAudioPackets addObject:pkt];
      }
      av_packet_unref(_packet);
      continue;
    }

    // Video - collect
    if (_packet->stream_index == _videoStreamIndex) {
      double packetPTS = (double)_packet->pts * av_q2d(stream->time_base);

      FFmpegDemuxerPacket *pkt = [self createPacketFromAV:_packet
                                                  isVideo:YES
                                                  isAudio:NO
                                               isSubtitle:NO];
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
      FFmpegDemuxerPacket *pkt = [self createPacketFromAV:_packet
                                                  isVideo:YES
                                                  isAudio:NO
                                               isSubtitle:NO];
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

- (nullable NSArray<FFmpegAudioTrackInfo *> *)getAudioTracks {
  if (_audioStreamIndices.count == 0) {
    return nil;
  }

  NSMutableArray<FFmpegAudioTrackInfo *> *tracks = [NSMutableArray array];

  for (NSNumber *streamIndexNum in _audioStreamIndices) {
    int streamIndex = [streamIndexNum intValue];
    AVStream *stream = _formatContext->streams[streamIndex];
    AVCodecParameters *codecPars = stream->codecpar;
    const AVCodec *codec = avcodec_find_decoder(codecPars->codec_id);

    FFmpegAudioTrackInfo *track = [[FFmpegAudioTrackInfo alloc] init];
    track.streamIndex = streamIndex;
    track.codecName =
        codec ? [NSString stringWithUTF8String:codec->name] : @"unknown";
    track.sampleRate = codecPars->sample_rate;
    track.channels = codecPars->ch_layout.nb_channels;
    // Only mark as default if this is the stream the demuxer selected as
    // default
    track.isDefault = (streamIndex == _audioStreamIndex);

    // Extract metadata
    AVDictionaryEntry *lang =
        av_dict_get(stream->metadata, "language", NULL, 0);
    if (lang && lang->value) {
      track.language = [NSString stringWithUTF8String:lang->value];
    }

    AVDictionaryEntry *title = av_dict_get(stream->metadata, "title", NULL, 0);
    if (title && title->value) {
      track.title = [NSString stringWithUTF8String:title->value];
    }

    [tracks addObject:track];
  }

  return tracks;
}

- (BOOL)selectAudioStream:(int)streamIndex {
  // Verify the stream index is valid and is an audio stream
  if (streamIndex < 0 ||
      (unsigned int)streamIndex >= _formatContext->nb_streams) {
    return NO;
  }

  if (_formatContext->streams[streamIndex]->codecpar->codec_type !=
      AVMEDIA_TYPE_AUDIO) {
    return NO;
  }

  _audioStreamIndex = streamIndex;
  return YES;
}

- (int)selectedAudioStreamIndex {
  return _audioStreamIndex;
}

- (void)close {
  if (!_formatContext) {
    return;
  }

  if (_packet) {
    av_packet_free(&_packet);
    _packet = NULL;
  }

  if (_formatContext) {
    avformat_close_input(&_formatContext);
    _formatContext = NULL;
  }

  [_queuedAudioPackets removeAllObjects];
  [_audioStreamIndices removeAllObjects];
  [_subtitleStreamIndices removeAllObjects];
  _videoStreamIndex = -1;
  _audioStreamIndex = -1;
  _subtitleStreamIndex = -1;
}

- (nullable NSArray<FFmpegSubtitleTrackInfo *> *)getSubtitleTracks {
  if (_subtitleStreamIndices.count == 0) {
    return nil;
  }

  NSMutableArray<FFmpegSubtitleTrackInfo *> *tracks = [NSMutableArray array];

  for (NSNumber *streamIndexNum in _subtitleStreamIndices) {
    int streamIndex = [streamIndexNum intValue];
    AVStream *stream = _formatContext->streams[streamIndex];
    AVCodecParameters *codecPars = stream->codecpar;
    const AVCodec *codec = avcodec_find_decoder(codecPars->codec_id);

    FFmpegSubtitleTrackInfo *track = [[FFmpegSubtitleTrackInfo alloc] init];
    track.streamIndex = streamIndex;
    track.codecName =
        codec ? [NSString stringWithUTF8String:codec->name] : @"unknown";
    track.isDefault = (streamIndex == _subtitleStreamIndex);

    // Bitmap check
    track.isBitmap = (codecPars->codec_id == AV_CODEC_ID_DVD_SUBTITLE ||
                      codecPars->codec_id == AV_CODEC_ID_HDMV_PGS_SUBTITLE ||
                      codecPars->codec_id == AV_CODEC_ID_DVB_SUBTITLE ||
                      codecPars->codec_id == AV_CODEC_ID_XSUB);

    // Extract metadata
    AVDictionaryEntry *lang =
        av_dict_get(stream->metadata, "language", NULL, 0);
    if (lang && lang->value) {
      track.language = [NSString stringWithUTF8String:lang->value];
    }

    AVDictionaryEntry *title = av_dict_get(stream->metadata, "title", NULL, 0);
    if (title && title->value) {
      track.title = [NSString stringWithUTF8String:title->value];
    }

    [tracks addObject:track];
  }

  return tracks;
}

- (BOOL)selectSubtitleStream:(int)streamIndex {
  if (streamIndex < 0) {
    _subtitleStreamIndex = -1;
    return YES;
  }

  if ((unsigned int)streamIndex >= _formatContext->nb_streams)
    return NO;
  if (_formatContext->streams[streamIndex]->codecpar->codec_type !=
      AVMEDIA_TYPE_SUBTITLE)
    return NO;

  _subtitleStreamIndex = streamIndex;
  return YES;
}

- (int)selectedSubtitleStreamIndex {
  return _subtitleStreamIndex;
}

- (NSData *)parseAmbientViewingEnvironment:
    (const AVAmbientViewingEnvironment *)env {
  // Convert to 8-byte SEI format: illuminance(32) + x(16) + y(16)
  uint32_t ill = (uint32_t)round(av_q2d(env->ambient_illuminance) * 10000.0);
  uint16_t x = (uint16_t)round(av_q2d(env->ambient_light_x) * 50000.0);
  uint16_t y = (uint16_t)round(av_q2d(env->ambient_light_y) * 50000.0);

  uint8_t packed[8];
  packed[0] = (ill >> 24) & 0xFF;
  packed[1] = (ill >> 16) & 0xFF;
  packed[2] = (ill >> 8) & 0xFF;
  packed[3] = ill & 0xFF;
  packed[4] = (x >> 8) & 0xFF;
  packed[5] = x & 0xFF;
  packed[6] = (y >> 8) & 0xFF;
  packed[7] = y & 0xFF;

  return [NSData dataWithBytes:packed length:8];
}

#pragma mark - Private Helpers

- (FFmpegDemuxerPacket *)createPacketFromAV:(AVPacket *)pkt
                                    isVideo:(BOOL)isVideo
                                    isAudio:(BOOL)isAudio
                                 isSubtitle:(BOOL)isSubtitle {
  FFmpegDemuxerPacket *packet = [[FFmpegDemuxerPacket alloc] init];
  AVPacket *packetRef = av_packet_alloc();
  if (packetRef && av_packet_ref(packetRef, pkt) == 0) {
    [packet setBackingPacket:packetRef];
  } else if (packetRef) {
    av_packet_free(&packetRef);
  }

  packet.pts = pkt->pts;
  packet.dts = pkt->dts;
  packet.duration = pkt->duration;
  packet.isVideo = isVideo;
  packet.isAudio = isAudio;
  packet.isSubtitle = isSubtitle;
  packet.isKeyframe = (pkt->flags & AV_PKT_FLAG_KEY) != 0;

  if (packetRef && packetRef->data && packetRef->size > 0) {
    packet.data =
        [NSData dataWithBytesNoCopy:packetRef->data
                             length:packetRef->size
                       freeWhenDone:NO];
    packet.size = packetRef->size;
  } else if (pkt->data && pkt->size > 0) {
    // Fallback path if packet ref could not be retained.
    packet.data = [NSData dataWithBytes:pkt->data length:pkt->size];
    packet.size = pkt->size;
  } else {
    packet.data = [NSData data];
    packet.size = 0;
  }

  // Extract Ambient Viewing Environment side data
  // Extract Ambient Viewing Environment side data
  const AVPacketSideData *amveSideData =
      av_packet_side_data_get(pkt->side_data, pkt->side_data_elems,
                              AV_PKT_DATA_AMBIENT_VIEWING_ENVIRONMENT);

  if (amveSideData &&
      amveSideData->size >= sizeof(AVAmbientViewingEnvironment)) {
    const AVAmbientViewingEnvironment *env =
        (const AVAmbientViewingEnvironment *)amveSideData->data;
    packet.ambientLightMetadata = [self parseAmbientViewingEnvironment:env];
  } else {
    // Fallback: check stream side data
    AVStream *stream = _formatContext->streams[pkt->stream_index];
    const AVPacketSideData *streamAmve = av_packet_side_data_get(
        stream->codecpar->coded_side_data, stream->codecpar->nb_coded_side_data,
        AV_PKT_DATA_AMBIENT_VIEWING_ENVIRONMENT);

    if (streamAmve && streamAmve->size >= sizeof(AVAmbientViewingEnvironment)) {
      const AVAmbientViewingEnvironment *env =
          (const AVAmbientViewingEnvironment *)streamAmve->data;
      packet.ambientLightMetadata = [self parseAmbientViewingEnvironment:env];
    }
  }

  return packet;
}

@end
