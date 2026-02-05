//
//  FrameRefWrapper.mm
//  VidCore
//
//  Implementation of thread-safe AVFrame reference wrapper
//

// Fix for AVMediaType collision between AVFoundation and FFmpeg
#define AVMediaType FFmpegAVMediaType
#import "FFmpegBridge.h"
#undef AVMediaType

#import "FrameRefWrapper.h"
#import <os/log.h>

@interface FrameRefWrapper ()
@property(nonatomic, assign) AVFrame *frame;
@end

@implementation FrameRefWrapper

- (instancetype)initWithFrame:(AVFrame *)frame {
  if (!frame) {
    return nil;
  }

  self = [super init];
  if (self) {
    // Allocate our own AVFrame and reference the input frame
    // This increments FFmpeg's internal atomic reference count
    _frame = av_frame_alloc();
    if (!_frame) {
      return nil;
    }

    // av_frame_ref increments the reference count on the underlying buffers
    // This is thread-safe (uses atomic operations internally)
    int ret = av_frame_ref(_frame, frame);
    if (ret < 0) {
      av_frame_free(&_frame);
      _frame = NULL;
      return nil;
    }
  }
  return self;
}

- (void)dealloc {
  if (_frame) {
    // Decrement reference count and free if last reference
    // Thread-safe - can be called from any thread
    av_frame_unref(_frame);
    av_frame_free(&_frame);
    _frame = NULL;
  }
}

@end

#pragma mark - CVPixelBuffer Release Callback

void FrameRefWrapper_ReleaseCallback(void *refCon, const void *dataPtr,
                                     size_t dataSize, size_t numberOfPlanes,
                                     const void *planeAddresses[]) {
  // Transfer ownership from __bridge_retained back to ARC
  // This will trigger dealloc when the transfer completes
  FrameRefWrapper *wrapper = (__bridge_transfer FrameRefWrapper *)refCon;

  // wrapper will be deallocated at the end of this scope
  // triggering av_frame_unref in dealloc
  (void)wrapper; // Suppress unused variable warning
  (void)dataPtr;
  (void)dataSize;
  (void)numberOfPlanes;
  (void)planeAddresses;
}
