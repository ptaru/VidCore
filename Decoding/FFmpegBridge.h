//
//  FFmpegBridge.h
//  VidCore
//
//  FFmpeg C library imports for Objective-C++
//

#ifndef FFmpegBridge_h
#define FFmpegBridge_h

// Import FFmpeg headers with extern "C" wrapper for C++
#ifdef __cplusplus
extern "C" {
#endif

#import <libavcodec/avcodec.h>
#import <libavformat/avformat.h>
#import <libavutil/avutil.h>
#import <libavutil/hwcontext.h>
#import <libavutil/imgutils.h>
#import <libswresample/swresample.h>
#import <libswscale/swscale.h>

#ifdef __cplusplus
}
#endif

#endif /* FFmpegBridge_h */
