//
//  PixelFormatConverter.mm
//  VidCore
//
//  Converts FFmpeg AVFrame pixel formats to CVPixelBuffer
//

// Fix for AVMediaType collision between AVFoundation and FFmpeg
#define AVMediaType FFmpegAVMediaType
#import "FFmpegBridge.h"
#undef AVMediaType

#import "AccelerateHelper.h"
#import "PixelFormatConverter.h"

@interface PixelFormatConverter ()
@property(nonatomic, assign) SwsContext *swsContext;
@property(nonatomic, assign) CVPixelBufferPoolRef i420BufferPool;
@property(nonatomic, assign) CVPixelBufferPoolRef p010BufferPool;
@property(nonatomic, assign) int poolWidth;
@property(nonatomic, assign) int poolHeight;
@property(nonatomic, assign) BOOL hasCreatedP010Pool;
@end

@implementation PixelFormatConverter

- (instancetype)init {
  self = [super init];
  if (self) {
    _swsContext = NULL;
    _i420BufferPool = NULL;
    _p010BufferPool = NULL;
    _poolWidth = 0;
    _poolHeight = 0;
    _hasCreatedP010Pool = NO;
  }
  return self;
}

- (void)dealloc {
  [self cleanup];
}

- (nullable CVPixelBufferRef)convertFrame:(AVFrame *)frame {
  // Output YUV420P directly - Metal shader handles YUV→RGB conversion on GPU
  // This eliminates CPU sws_scale overhead entirely

  CVPixelBufferRef pixelBuffer = NULL;

  // Check if input is already YUV420P (most common software decode output)
  if (frame->format == AV_PIX_FMT_YUV420P) {
    pixelBuffer = [self convertYUV420PFrame:frame];
    return pixelBuffer;
  }

  // Handle 10-bit YUV420P10LE - output as P010 to preserve HDR data
  if (frame->format == AV_PIX_FMT_YUV420P10LE) {
    pixelBuffer = [self convertYUV420P10LEFrame:frame];
    return pixelBuffer;
  }

  // For other formats (NV12, YUV422, etc.), use sws_scale to convert to NV12
  return [self convertOtherFormatFrame:frame];
}

#pragma mark - Private Conversion Methods

- (nullable CVPixelBufferRef)convertYUV420PFrame:(AVFrame *)frame {
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
      (__bridge NSString *)
      kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_420YpCbCr8Planar),
      (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey : @{}
    };

    CVReturn status = CVPixelBufferPoolCreate(
        kCFAllocatorDefault, (__bridge CFDictionaryRef)poolAttributes,
        (__bridge CFDictionaryRef)pixelBufferAttributes, &_i420BufferPool);

    if (status != kCVReturnSuccess) {
      NSLog(@"[PixelFormatConverter] Failed to create I420 pixel buffer pool");
      return NULL;
    }

    _poolWidth = frame->width;
    _poolHeight = frame->height;
    NSLog(@"[PixelFormatConverter] Created I420 buffer pool: %dx%d", _poolWidth,
          _poolHeight);
  }

  // Get buffer from pool
  CVPixelBufferRef pixelBuffer = NULL;
  CVReturn status =
      CVPixelBufferPoolCreatePixelBuffer(NULL, _i420BufferPool, &pixelBuffer);
  if (status != kCVReturnSuccess) {
    NSLog(@"[PixelFormatConverter] Failed to get buffer from pool: %d", status);
    return NULL;
  }

  // Delegate copy to AccelerateHelper (avoids header conflicts)
  [AccelerateHelper copyYUV420PToBuffer:pixelBuffer
                                   srcY:frame->data[0]
                                   srcU:frame->data[1]
                                   srcV:frame->data[2]
                            srcLinesize:frame->linesize
                                  width:frame->width
                                 height:frame->height];
  return pixelBuffer;
}

- (nullable CVPixelBufferRef)convertYUV420P10LEFrame:(AVFrame *)frame {
  // Use CVPixelBufferPool for efficient P010 buffer reuse
  // This is critical for 4K HDR content to avoid massive memory churn
  // Lazy initialization: only create P010 pool when first HDR frame is detected
  if (!_hasCreatedP010Pool || !_p010BufferPool || _poolWidth != frame->width ||
      _poolHeight != frame->height) {
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
      NSLog(@"[PixelFormatConverter] Failed to create P010 pixel buffer pool");
      return NULL;
    }

    _poolWidth = frame->width;
    _poolHeight = frame->height;
    _hasCreatedP010Pool = YES;
    NSLog(@"[PixelFormatConverter] Lazy-created P010 buffer pool: %dx%d",
          _poolWidth, _poolHeight);
  }

  // Get buffer from pool
  CVPixelBufferRef pixelBuffer = NULL;
  CVReturn status =
      CVPixelBufferPoolCreatePixelBuffer(NULL, _p010BufferPool, &pixelBuffer);
  if (status != kCVReturnSuccess) {
    NSLog(@"[PixelFormatConverter] Failed to get P010 buffer from pool: %d",
          status);
    return NULL;
  }

  [AccelerateHelper copyYUV420P10LEToBuffer:pixelBuffer
                                       srcY:(const uint16_t *)frame->data[0]
                                       srcU:(const uint16_t *)frame->data[1]
                                       srcV:(const uint16_t *)frame->data[2]
                                srcLinesize:frame->linesize
                                      width:frame->width
                                     height:frame->height];
  return pixelBuffer;
}

- (nullable CVPixelBufferRef)convertOtherFormatFrame:(AVFrame *)frame {
  // For other formats (NV12, YUV422, etc.), use sws_scale to convert to NV12
  // This is a fallback path - most software decoding outputs YUV420P
  if (!_swsContext) {
    _swsContext = sws_getContext(frame->width, frame->height,
                                 (enum AVPixelFormat)frame->format,
                                 frame->width, frame->height, AV_PIX_FMT_NV12,
                                 SWS_BILINEAR, NULL, NULL, NULL);
    if (!_swsContext) {
      NSLog(@"[PixelFormatConverter] Failed to create sws context");
      return NULL;
    }
  }

  NSDictionary *nv12Attributes =
      @{(__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey : @{}};

  CVPixelBufferRef pixelBuffer = NULL;
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

- (void)cleanup {
  if (_swsContext) {
    sws_freeContext(_swsContext);
    _swsContext = NULL;
  }

  if (_i420BufferPool) {
    CVPixelBufferPoolFlush(_i420BufferPool,
                           kCVPixelBufferPoolFlushExcessBuffers);
    CVPixelBufferPoolRelease(_i420BufferPool);
    _i420BufferPool = NULL;
    NSLog(@"[PixelFormatConverter] I420 buffer pool flushed and released");
  }

  if (_p010BufferPool) {
    CVPixelBufferPoolFlush(_p010BufferPool,
                           kCVPixelBufferPoolFlushExcessBuffers);
    CVPixelBufferPoolRelease(_p010BufferPool);
    _p010BufferPool = NULL;
    _hasCreatedP010Pool = NO;
    NSLog(@"[PixelFormatConverter] P010 buffer pool flushed and released");
  }

  _poolWidth = 0;
  _poolHeight = 0;
}

@end
