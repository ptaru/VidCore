//
//  LibASSRenderer.mm
//  VidCore
//
//  Created by Unchecked Sendable on 2026-02-07.
//

#import "LibASSRenderer.h"

extern "C" {
#include <ass/ass.h>
}

@implementation LibASSRenderer {
  ASS_Library *_assLibrary;
  ASS_Renderer *_assRenderer;
  ASS_Track *_assTrack;

  CGSize _storageSize;
  double _aspect;

  CGSize _lastSize;
  CGFloat _lastScale;
  dispatch_queue_t _renderQueue;

  NSString *_cachedHeader; // Cache header to restore after flush

  // Optimizations
  CGImageRef _cachedImage;
  uint8_t *_pixelBuffer;
  size_t _pixelBufferSize;
  int _lastRenderChanged;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _renderQueue =
        dispatch_queue_create("com.vidpreview.libass", DISPATCH_QUEUE_SERIAL);

    _assLibrary = ass_library_init();
    if (!_assLibrary) {
      return nil;
    }

    // Initialize renderer
    _assRenderer = ass_renderer_init(_assLibrary);
    if (!_assRenderer) {
      ass_library_done(_assLibrary);
      return nil;
    }

    // Configure fonts (autodetect provider, sans-serif fallback).
    ass_set_fonts(_assRenderer, NULL, "sans-serif", ASS_FONTPROVIDER_AUTODETECT,
                  NULL, 1);

    _assTrack = ass_new_track(_assLibrary);
  }
  return self;
}

- (void)dealloc {
  if (_assTrack)
    ass_free_track(_assTrack);
  if (_assRenderer)
    ass_renderer_done(_assRenderer);
  if (_assLibrary)
    ass_library_done(_assLibrary);
  if (_cachedImage)
    CGImageRelease(_cachedImage);
  if (_pixelBuffer)
    free(_pixelBuffer);
}

- (void)configureWithHeader:(NSString *)header {
  if (!header || header.length == 0)
    return;

  // Cache the header
  self->_cachedHeader = header;

  dispatch_sync(_renderQueue, ^{
    const char *data = [header cStringUsingEncoding:NSUTF8StringEncoding];
    if (data) {
      ass_process_codec_private(_assTrack, (char *)data, (int)strlen(data));
    }
  });
}

- (void)setStorageSize:(CGSize)storageSize aspect:(double)aspect {
  dispatch_async(_renderQueue, ^{
    if (!CGSizeEqualToSize(storageSize, self->_storageSize) ||
        aspect != self->_aspect) {
      self->_storageSize = storageSize;
      self->_aspect = aspect;

      if (storageSize.width > 0 && storageSize.height > 0) {
        ass_set_storage_size(self->_assRenderer, (int)storageSize.width,
                             (int)storageSize.height);
      }
      if (aspect > 0) {
        ass_set_pixel_aspect(self->_assRenderer, aspect);
      }
    }
  });
}

- (void)processPacket:(NSData *)data pts:(double)pts duration:(double)duration {
  if (!data || data.length == 0)
    return;

  dispatch_async(_renderQueue, ^{
    char *entry = (char *)data.bytes;
    int len = (int)data.length;

    // Check if it starts with a digit (Layer/ReadOrder)
    if (len > 0 && isdigit(entry[0])) {
      // Convert Matroska ASS packets to "Dialogue: Layer,Start,End,Style,..."

      // Parse the first two fields
      NSString *rawStr = [[NSString alloc] initWithData:data
                                               encoding:NSUTF8StringEncoding];
      if (!rawStr)
        return;

      // Find commas
      NSRange firstComma = [rawStr rangeOfString:@","];
      if (firstComma.location != NSNotFound) {
        NSString *layerStr = [rawStr substringToIndex:firstComma.location];

        // Skip the ReadOrder placeholder between the first two commas.
        NSRange searchRange = NSMakeRange(
            firstComma.location + 1, rawStr.length - (firstComma.location + 1));
        NSRange secondComma = [rawStr rangeOfString:@","
                                            options:0
                                              range:searchRange];

        if (secondComma.location != NSNotFound) {
          // The rest of the string starting from Style
          NSString *restStr =
              [rawStr substringFromIndex:secondComma.location + 1];

          // Format timestamps
          NSString *startStr = [self formatASSTime:pts];
          NSString *endStr = [self formatASSTime:(pts + duration)];

          // Construct proper Dialogue line
          NSString *eventLine =
              [NSString stringWithFormat:@"Dialogue: %@,%@,%@,%@", layerStr,
                                         startStr, endStr, restStr];

          const char *processedData =
              [eventLine cStringUsingEncoding:NSUTF8StringEncoding];
          if (processedData) {
            ass_process_data(self->_assTrack, (char *)processedData,
                             (int)strlen(processedData));
          }
          return;
        }
      }

      // Fallback if parsing failed but looks like raw data
      NSMutableData *fixedData = [NSMutableData data];
      const char *prefix = "Dialogue: ";
      [fixedData appendBytes:prefix length:strlen(prefix)];
      [fixedData appendData:data];
      ass_process_data(self->_assTrack, (char *)fixedData.bytes,
                       (int)fixedData.length);
    } else {
      ass_process_data(self->_assTrack, (char *)data.bytes, (int)data.length);
    }
  });
}

- (NSString *)formatASSTime:(double)seconds {
  int h = (int)(seconds / 3600.0);
  int m = (int)((seconds - h * 3600) / 60.0);
  int s = (int)(seconds - h * 3600 - m * 60);
  int cs = (int)((seconds - (int)seconds) * 100.0);
  return [NSString stringWithFormat:@"%d:%02d:%02d.%02d", h, m, s, cs];
}

- (void)flush {
  dispatch_async(_renderQueue, ^{
    // Re-create track to clear events
    if (self->_assTrack) {
      ass_free_track(self->_assTrack);
    }
    self->_assTrack = ass_new_track(self->_assLibrary);

    // Clear cached image on flush
    if (self->_cachedImage) {
      CGImageRelease(self->_cachedImage);
      self->_cachedImage = NULL;
    }

    // Restore header if available
    if (self->_cachedHeader) {
      const char *data =
          [self->_cachedHeader cStringUsingEncoding:NSUTF8StringEncoding];
      if (data) {
        ass_process_codec_private(self->_assTrack, (char *)data,
                                  (int)strlen(data));
      }
    }
  });
}

- (CGImageRef)renderAtTimestamp:(double)timestamp
                           size:(CGSize)size
                          scale:(CGFloat)scale {
  if (size.width <= 0 || size.height <= 0) {
    return NULL;
  }

  __block CGImageRef resultImage = NULL;

  dispatch_sync(_renderQueue, ^{
    long long now_ms = (long long)(timestamp * 1000);

    // Update size if changed
    BOOL sizeChanged =
        !CGSizeEqualToSize(size, self->_lastSize) || scale != self->_lastScale;
    if (sizeChanged) {
      ass_set_frame_size(self->_assRenderer, (int)(size.width * scale),
                         (int)(size.height * scale));
      self->_lastSize = size;
      self->_lastScale = scale;

      // Clear cached image on resize
      if (self->_cachedImage) {
        CGImageRelease(self->_cachedImage);
        self->_cachedImage = NULL;
      }
    }

    // Render
    int changed = 0;
    ASS_Image *img =
        ass_render_frame(self->_assRenderer, self->_assTrack, now_ms, &changed);
    self->_lastRenderChanged = changed;

    // Reuse cached image when libass reports no changes.
    if (!changed && self->_cachedImage && !sizeChanged) {
      resultImage = CGImageRetain(self->_cachedImage);
      return;
    }

    if (!img) {
      if (self->_cachedImage) {
        CGImageRelease(self->_cachedImage);
        self->_cachedImage = NULL;
      }
      return;
    }

    // Blend ASS images into a single RGBA buffer
    int width = (int)(size.width * scale);
    int height = (int)(size.height * scale);
    size_t newSize = width * height * 4;

    // Allocate or reuse buffer
    if (!self->_pixelBuffer || self->_pixelBufferSize < newSize) {
      if (self->_pixelBuffer)
        free(self->_pixelBuffer);
      self->_pixelBuffer = (uint8_t *)calloc(1, newSize);
      self->_pixelBufferSize = newSize;
    } else {
      memset(self->_pixelBuffer, 0, newSize);
    }

    // Blend ASS images into an RGBA buffer.
    ASS_Image *curr = img;
    while (curr) {
      if (curr->w > 0 && curr->h > 0) {
        uint32_t color = curr->color;
        uint8_t r = (color >> 24) & 0xFF;
        uint8_t g = (color >> 16) & 0xFF;
        uint8_t b = (color >> 8) & 0xFF;
        uint8_t a = 255 - (color & 0xFF); // opacity

        if (a > 0) {
          for (int y = 0; y < curr->h; ++y) {
            int dst_y = curr->dst_y + y;
            if (dst_y < 0 || dst_y >= height)
              continue;

            uint8_t *src_line = curr->bitmap + y * curr->stride;
            uint8_t *dst_line =
                self->_pixelBuffer + (dst_y * width + curr->dst_x) * 4;

            for (int x = 0; x < curr->w; ++x) {
              int dst_x = curr->dst_x + x;
              if (dst_x < 0 || dst_x >= width)
                continue;

              uint8_t src_alpha = src_line[x];
              if (src_alpha == 0) {
                dst_line += 4;
                continue;
              }

              // Combine libass opacity with bitmap alpha.
              uint32_t final_alpha = (src_alpha * a) / 255;

              uint8_t *dst_pixel = dst_line;
              uint32_t inv_alpha = 255 - final_alpha;

              uint32_t pr = (r * final_alpha) / 255;
              uint32_t pg = (g * final_alpha) / 255;
              uint32_t pb = (b * final_alpha) / 255;
              uint32_t pa = final_alpha;

              dst_pixel[0] = (uint8_t)(pr + (dst_pixel[0] * inv_alpha) / 255);
              dst_pixel[1] = (uint8_t)(pg + (dst_pixel[1] * inv_alpha) / 255);
              dst_pixel[2] = (uint8_t)(pb + (dst_pixel[2] * inv_alpha) / 255);
              dst_pixel[3] = (uint8_t)(pa + (dst_pixel[3] * inv_alpha) / 255);

              dst_line += 4;
            }
          }
        }
      }
      curr = curr->next;
    }

    // Create CGImage from buffer
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx =
        CGBitmapContextCreate(self->_pixelBuffer, width, height, 8, width * 4,
                              colorSpace, kCGImageAlphaPremultipliedLast);

    if (ctx) {
      if (self->_cachedImage)
        CGImageRelease(self->_cachedImage);
      self->_cachedImage = CGBitmapContextCreateImage(ctx);
      resultImage = CGImageRetain(self->_cachedImage);
      CGContextRelease(ctx);
    }

    CGColorSpaceRelease(colorSpace);
  });

  return resultImage;
}

@end
