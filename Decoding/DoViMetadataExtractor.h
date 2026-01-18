//
//  DoViMetadataExtractor.h
//  VidCore
//
//  Extracts Dolby Vision Profile 5 metadata from FFmpeg decoded frames
//

#import <Foundation/Foundation.h>

// Forward declaration to avoid exposing FFmpeg types in header
struct AVFrame;

NS_ASSUME_NONNULL_BEGIN

/// Utility class for extracting Dolby Vision metadata from video frames.
/// Only processes Profile 5 (IPTPQc2); Profile 8 returns nil for standard HDR fallback.
@interface DoViMetadataExtractor : NSObject

/// Extract DoVi Profile 5 metadata from an FFmpeg frame.
/// @param frame The decoded AVFrame containing potential DoVi side data
/// @return Dictionary with reshape curves, matrices, and scene brightness, or nil if not Profile 5
+ (nullable NSDictionary *)extractMetadataFromFrame:(struct AVFrame *)frame;

@end

NS_ASSUME_NONNULL_END
