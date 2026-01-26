//
//  DoViMetadataExtractor.mm
//  VidCore
//
//  Extracts Dolby Vision Profile 5 metadata from FFmpeg decoded frames
//

// Fix for AVMediaType collision between AVFoundation and FFmpeg
#define AVMediaType FFmpegAVMediaType
#import "FFmpegBridge.h"
#undef AVMediaType

#import "DoViMetadataExtractor.h"

@implementation DoViMetadataExtractor

+ (nullable NSDictionary *)extractMetadataFromFrame:(AVFrame *)frame {
  AVFrameSideData *sd =
      av_frame_get_side_data(frame, AV_FRAME_DATA_DOVI_METADATA);
  if (!sd)
    return nil;

  const AVDOVIMetadata *metadata = (AVDOVIMetadata *)sd->data;
  const AVDOVIRpuDataHeader *header = av_dovi_get_header(metadata);

  // Process RPU metadata regardless of profile
  // Note: Profile 5 is single-layer (disable_residual_flag = 1)
  // Profile 7 is dual-layer (disable_residual_flag = 0), but the RPU is still
  // valid for the base layer. Profile 8 is single-layer.

  // Log only once per session to avoid spam
  static int lastLoggedProfile = -1;
  
  // Infer profile for logging (5=Full Range, 7=Dual Layer, 8=Limited Range Single Layer)
  int inferredProfile = 0;
  if (header->bl_video_full_range_flag) {
      inferredProfile = 5;
  } else if (header->disable_residual_flag == 0) {
      inferredProfile = 7;
  } else {
      inferredProfile = 8;
  }

  if (inferredProfile != lastLoggedProfile) {
    NSLog(@"[DoViMetadataExtractor] Processing DoVi Profile %d metadata (%@ Range%@)",
          inferredProfile, 
          header->bl_video_full_range_flag ? @"Full" : @"Limited",
          header->disable_residual_flag ? @"" : @", Dual Layer");
    lastLoggedProfile = inferredProfile;
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
        NSLog(@"[DoViMetadataExtractor] L1 scene brightness: max=%.3f avg=%.3f",
              dm->l1.max_pq / 4095.0f, dm->l1.avg_pq / 4095.0f);
        loggedL1 = YES;
      }
      break;
    }
  }

  return result;
}

@end
