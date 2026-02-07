//
//  LibASSRenderer.h
//  VidCore
//
//  Created by Unchecked Sendable on 2026-02-07.
//

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Wrapper around libass for rendering ASS/SSA subtitles.
@interface LibASSRenderer : NSObject

/// Configure the renderer with the ASS track header (usually from codec
/// extradata).
- (void)configureWithHeader:(NSString *)header;

/// Feed a subtitle packet to the renderer.
/// @param data The raw packet data containing the ASS event line.
/// @param pts Presentation timestamp in seconds.
/// @param duration Duration in seconds.
- (void)processPacket:(NSData *)data pts:(double)pts duration:(double)duration;

- (void)setStorageSize:(CGSize)storageSize aspect:(double)aspect;

/// Render the subtitles at a specific timestamp and resolution.
/// @param timestamp The current playback time in seconds.
/// @param size The size of the video/view in points (or pixels depending on
/// scale).
/// @param scale The retina scale factor (e.g. 2.0 or 3.0).
/// @return A CGImageRef containing the rendered subtitles with transparent
/// background, or NULL.
- (nullable CGImageRef)renderAtTimestamp:(double)timestamp
                                    size:(CGSize)size
                                   scale:(CGFloat)scale CF_RETURNS_RETAINED;

/// Clear all buffered events.
- (void)flush;

@end

NS_ASSUME_NONNULL_END
