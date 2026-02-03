//
//  AccelerateHelper.m
//  VidCore
//
//  Helper class to isolate Accelerate framework usage from FFmpeg conflicts.
//

#import "AccelerateHelper.h"
#import <Accelerate/Accelerate.h>

@implementation AccelerateHelper

+ (void)copyYUV420PToBuffer:(CVPixelBufferRef)pixelBuffer
                       srcY:(const uint8_t *)srcY
                       srcU:(const uint8_t *)srcU
                       srcV:(const uint8_t *)srcV
                srcLinesize:(const int *)srcLinesize
                      width:(int)width
                     height:(int)height {

  CVPixelBufferLockBaseAddress(pixelBuffer, 0);

  // Y Plane
  vImage_Buffer ySrcBuffer = {.data = (void *)srcY,
                              .height = (vImagePixelCount)height,
                              .width = (vImagePixelCount)width,
                              .rowBytes = (size_t)srcLinesize[0]};

  vImage_Buffer yDestBuffer = {
      .data = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
      .height = (vImagePixelCount)height,
      .width = (vImagePixelCount)width,
      .rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)};

  vImageCopyBuffer(&ySrcBuffer, &yDestBuffer, 1, kvImageNoFlags);

  // U Plane
  int uvHeight = height / 2;
  int uvWidth = width / 2;

  vImage_Buffer uSrcBuffer = {.data = (void *)srcU,
                              .height = (vImagePixelCount)uvHeight,
                              .width = (vImagePixelCount)uvWidth,
                              .rowBytes = (size_t)srcLinesize[1]};

  vImage_Buffer uDestBuffer = {
      .data = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1),
      .height = (vImagePixelCount)uvHeight,
      .width = (vImagePixelCount)uvWidth,
      .rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)};

  vImageCopyBuffer(&uSrcBuffer, &uDestBuffer, 1, kvImageNoFlags);

  // V Plane
  vImage_Buffer vSrcBuffer = {.data = (void *)srcV,
                              .height = (vImagePixelCount)uvHeight,
                              .width = (vImagePixelCount)uvWidth,
                              .rowBytes = (size_t)srcLinesize[2]};

  vImage_Buffer vDestBuffer = {
      .data = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 2),
      .height = (vImagePixelCount)uvHeight,
      .width = (vImagePixelCount)uvWidth,
      .rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 2)};

  vImageCopyBuffer(&vSrcBuffer, &vDestBuffer, 1, kvImageNoFlags);

  CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
}

+ (void)copyYUV420P10LEToBuffer:(CVPixelBufferRef)pixelBuffer
                           srcY:(const uint16_t *)srcY
                           srcU:(const uint16_t *)srcU
                           srcV:(const uint16_t *)srcV
                    srcLinesize:(const int *)srcLinesize
                          width:(int)width
                         height:(int)height {
  CVPixelBufferLockBaseAddress(pixelBuffer, 0);

  // Y plane - optimized row-wise copy with shift
  uint16_t *yDest =
      (uint16_t *)CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0);
  size_t yDestBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0);
  int ySrcStride = srcLinesize[0] / 2;

  for (int row = 0; row < height; row++) {
    uint16_t *srcRow = (uint16_t *)(srcY + row * ySrcStride);
    uint16_t *dstRow = (uint16_t *)((uint8_t *)yDest + row * yDestBytesPerRow);
    // Unrolled loop for better performance
    int col = 0;
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
  size_t uvDestBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1);
  int uSrcStride = srcLinesize[1] / 2;
  int vSrcStride = srcLinesize[2] / 2;
  int uvHeight = height / 2;
  int uvWidth = width / 2;

  for (int row = 0; row < uvHeight; row++) {
    uint16_t *uRow = (uint16_t *)(srcU + row * uSrcStride);
    uint16_t *vRow = (uint16_t *)(srcV + row * vSrcStride);
    uint16_t *dstRow =
        (uint16_t *)((uint8_t *)uvDest + row * uvDestBytesPerRow);
    for (int col = 0; col < uvWidth; col++) {
      dstRow[col * 2] = uRow[col] << 6;
      dstRow[col * 2 + 1] = vRow[col] << 6;
    }
  }

  CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
}

@end
