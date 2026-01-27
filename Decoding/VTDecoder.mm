//
//  VTDecoder.mm
//  VidCore
//
//  [description goes here]
//

#import "VTDecoder.h"

NSString * const VTDecoderErrorDomain = @"VTDecoderErrorDomain";

// Define hvcC atom key if not available (it should be in standard headers but just in case)
#ifndef kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
#define kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms CFSTR("SampleDescriptionExtensionAtoms")
#endif

@interface VTBufferedFrame : NSObject
@property (nonatomic, assign) CVPixelBufferRef buffer;
@property (nonatomic, assign) CMTime pts;
@end

@implementation VTBufferedFrame
- (void)dealloc {
    if (_buffer) CVPixelBufferRelease(_buffer);
}
- (void)setBuffer:(CVPixelBufferRef)buffer {
    if (_buffer) CVPixelBufferRelease(_buffer);
    _buffer = buffer;
    if (_buffer) CVPixelBufferRetain(_buffer);
}
@end

@interface VTDecoder () {
    VTDecompressionSessionRef _decompressionSession;
    CMVideoFormatDescriptionRef _formatDescription;
    AVRational _timeBase;
    
    // Dolby Vision support
    BOOL _isDolbyVision;
    uint8_t _dolbyVisionProfile;
    NSData *_dvcCData;  // Raw dvcC/dvvC atom bytes
    
    // Async support
    NSMutableArray<VTBufferedFrame *> *_asyncMutableQueue;
    NSLock *_queueLock;
    
    // Performance
    NSTimeInterval _totalDecodeTime;
    NSUInteger _decodeCount;
}
@end

@implementation VTDecoder

@synthesize isDolbyVision = _isDolbyVision;
@synthesize dolbyVisionProfile = _dolbyVisionProfile;

+ (BOOL)isCodecSupported:(enum AVCodecID)codecId {
    return codecId == AV_CODEC_ID_HEVC || codecId == AV_CODEC_ID_H264;
}

- (instancetype)initWithCodecParameters:(AVCodecParameters *)codecPars
                               timeBase:(AVRational)timeBase
                    dolbyVisionSideData:(nullable NSData *)doviConfigData
                                  error:(NSError **)error {
    self = [super init];
    if (self) {
        _timeBase = timeBase;
        _queueLock = [[NSLock alloc] init];
        _asyncMutableQueue = [NSMutableArray array];
        
        // Process Dolby Vision configuration if provided
        // FFmpeg's AVDOVIDecoderConfigurationRecord is an UNPACKED struct:
        //   uint8_t dv_version_major;     // offset 0
        //   uint8_t dv_version_minor;     // offset 1
        //   uint8_t dv_profile;           // offset 2
        //   uint8_t dv_level;             // offset 3
        //   uint8_t rpu_present_flag;     // offset 4
        //   uint8_t el_present_flag;      // offset 5
        //   uint8_t bl_present_flag;      // offset 6
        //   uint8_t dv_bl_signal_compatibility_id; // offset 7
        if (doviConfigData && doviConfigData.length >= 8) {
            const uint8_t *src = (const uint8_t *)doviConfigData.bytes;
            
            uint8_t dv_version_major = src[0];
            uint8_t dv_version_minor = src[1];
            uint8_t dv_profile = src[2];
            uint8_t dv_level = src[3];
            uint8_t rpu_present_flag = src[4];
            uint8_t el_present_flag = src[5];
            uint8_t bl_present_flag = src[6];
            uint8_t dv_bl_signal_compatibility_id = src[7];
            
            _isDolbyVision = YES;
            _dolbyVisionProfile = dv_profile;
            
            // Log the raw FFmpeg data as hex
            NSMutableString *inputHex = [NSMutableString string];
            for (NSUInteger i = 0; i < doviConfigData.length && i < 16; i++) {
                [inputHex appendFormat:@"%02X ", src[i]];
            }
            NSLog(@"[VTDecoder] FFmpeg DoVi config (%lu bytes): %@", 
                  (unsigned long)doviConfigData.length, inputHex);
            
            NSLog(@"[VTDecoder] Dolby Vision Profile %d Level %d detected (version %d.%d)",
                  dv_profile, dv_level, dv_version_major, dv_version_minor);
            NSLog(@"[VTDecoder] Flags: rpu=%d el=%d bl=%d compat_id=%d",
                  rpu_present_flag, el_present_flag, bl_present_flag, dv_bl_signal_compatibility_id);
            
            // Reconstruct the BIT-PACKED dvcC atom format for VideoToolbox:
            // The dvcC record is 24 bytes total according to actual MP4 files.
            // byte 0: dv_version_major
            // byte 1: dv_version_minor
            // byte 2: [dv_profile(7 bits)][dv_level bit 5]
            // byte 3: [dv_level bits 4:0][rpu_present][el_present][bl_present]
            // byte 4: [dv_bl_signal_compatibility_id(4 bits)][reserved(4 bits)]
            // bytes 5-23: reserved (zeros)
            uint8_t dvcC[24] = {0};  // Zero-initialize all 24 bytes
            dvcC[0] = dv_version_major;
            dvcC[1] = dv_version_minor;
            dvcC[2] = (dv_profile << 1) | ((dv_level >> 5) & 0x01);
            dvcC[3] = ((dv_level & 0x1F) << 3) | ((rpu_present_flag & 0x01) << 2) | 
                      ((el_present_flag & 0x01) << 1) | (bl_present_flag & 0x01);
            dvcC[4] = (dv_bl_signal_compatibility_id & 0x0F) << 4;
            // bytes 5-23 are all zeros (reserved)
            
            _dvcCData = [NSData dataWithBytes:dvcC length:24];
            
            // Log reconstructed dvcC as hex
            NSMutableString *dvcCHex = [NSMutableString string];
            for (int i = 0; i < 24; i++) {
                [dvcCHex appendFormat:@"%02X", dvcC[i]];
            }
            NSLog(@"[VTDecoder] Reconstructed dvcC (24 bytes): %@", dvcCHex);
        }
        
        if (![self createFormatDescription:codecPars error:error]) {
            return nil;
        }
        
        if (![self createDecompressionSession:error]) {
            return nil;
        }
    }
    return self;
}

- (void)dealloc {
    [self teardown];
}

- (void)teardown {
    if (_decompressionSession) {
        VTDecompressionSessionInvalidate(_decompressionSession);
        CFRelease(_decompressionSession);
        _decompressionSession = NULL;
    }
    if (_formatDescription) {
        CFRelease(_formatDescription);
        _formatDescription = NULL;
    }
    // _asyncMutableQueue is ARC managed
}

#pragma mark - Initialization

- (BOOL)createFormatDescription:(AVCodecParameters *)codecPars error:(NSError **)error {
    // 1. Prepare extensions dictionary
    if (!codecPars->extradata || codecPars->extradata_size == 0) {
        if (error) *error = [NSError errorWithDomain:VTDecoderErrorDomain code:VTDecoderErrorNoExtradata userInfo:@{NSLocalizedDescriptionKey: @"No extradata found for stream"}];
        return NO;
    }
    
    NSData *extradata = [NSData dataWithBytes:codecPars->extradata length:codecPars->extradata_size];
    
    NSString *atomKey = nil;
    CMVideoCodecType codecType = kCMVideoCodecType_HEVC;
    
    if (codecPars->codec_id == AV_CODEC_ID_HEVC) {
        // Check if this is Dolby Vision content
        if (_isDolbyVision) {
            codecType = kCMVideoCodecType_DolbyVisionHEVC;
            NSLog(@"[VTDecoder] Using Dolby Vision HEVC codec type");
        } else {
            codecType = kCMVideoCodecType_HEVC;
        }
        atomKey = @"hvcC";
    } else if (codecPars->codec_id == AV_CODEC_ID_H264) {
        codecType = kCMVideoCodecType_H264;
        atomKey = @"avcC";
    }
    
    NSMutableDictionary *atoms = [NSMutableDictionary dictionary];
    if (atomKey) {
        atoms[atomKey] = extradata;
    }
    
    // Add dvcC atom for Dolby Vision content
    if (_isDolbyVision && _dvcCData) {
        atoms[@"dvcC"] = _dvcCData;
        NSLog(@"[VTDecoder] Attaching dvcC atom (%lu bytes)", (unsigned long)_dvcCData.length);
    }
    
    NSMutableDictionary *extensions = [NSMutableDictionary dictionary];
    extensions[(__bridge NSString *)kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] = atoms;
    
    // Add color metadata
    // This allows VideoToolbox to know it's HDR content
    
    // Color Primaries
    if (codecPars->color_primaries == AVCOL_PRI_BT2020) {
        extensions[(__bridge NSString *)kCVImageBufferColorPrimariesKey] = (__bridge NSString *)kCVImageBufferColorPrimaries_ITU_R_2020;
    } else if (codecPars->color_primaries == AVCOL_PRI_BT709) {
        extensions[(__bridge NSString *)kCVImageBufferColorPrimariesKey] = (__bridge NSString *)kCVImageBufferColorPrimaries_ITU_R_709_2;
    }
    
    // Transfer Function
    if (codecPars->color_trc == AVCOL_TRC_SMPTE2084) { // PQ
        extensions[(__bridge NSString *)kCVImageBufferTransferFunctionKey] = (__bridge NSString *)kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ;
    } else if (codecPars->color_trc == AVCOL_TRC_ARIB_STD_B67) { // HLG
        extensions[(__bridge NSString *)kCVImageBufferTransferFunctionKey] = (__bridge NSString *)kCVImageBufferTransferFunction_ITU_R_2100_HLG;
    } else if (codecPars->color_trc == AVCOL_TRC_BT709) {
        extensions[(__bridge NSString *)kCVImageBufferTransferFunctionKey] = (__bridge NSString *)kCVImageBufferTransferFunction_ITU_R_709_2;
    }
    
    // YCbCr Matrix
    if (codecPars->color_space == AVCOL_SPC_BT2020_NCL) {
         extensions[(__bridge NSString *)kCVImageBufferYCbCrMatrixKey] = (__bridge NSString *)kCVImageBufferYCbCrMatrix_ITU_R_2020;
    } else if (codecPars->color_space == AVCOL_SPC_BT709) {
         extensions[(__bridge NSString *)kCVImageBufferYCbCrMatrixKey] = (__bridge NSString *)kCVImageBufferYCbCrMatrix_ITU_R_709_2;
    }
    
    OSStatus status = CMVideoFormatDescriptionCreate(
        kCFAllocatorDefault,
        codecType,
        codecPars->width,
        codecPars->height,
        (__bridge CFDictionaryRef)extensions,
        &_formatDescription
    );
    
    if (status != noErr) {
        if (error) *error = [NSError errorWithDomain:VTDecoderErrorDomain code:VTDecoderErrorFormatDescriptionCreationFailed userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"CMVideoFormatDescriptionCreate failed: %d", (int)status]}];
        return NO;
    }
    
    return YES;
}

static void outputCallback(void *decompressionOutputRefCon,
                           void *sourceFrameRefCon,
                           OSStatus status,
                           VTDecodeInfoFlags infoFlags,
                           CVImageBufferRef imageBuffer,
                           CMTime presentationTimeStamp,
                           CMTime presentationDuration) {
    if (status != noErr || !imageBuffer) return;
    
    VTDecoder *decoder = (__bridge VTDecoder *)decompressionOutputRefCon;
    BOOL isAsync = (sourceFrameRefCon == NULL); // convention: if sourceFrameRefCon is NULL, we are in async push mode
    
    if (!isAsync) {
        // Synchronous mode: sourceFrameRefCon is pointer to output buffer
        CVPixelBufferRef *outputBufferPtr = (CVPixelBufferRef *)sourceFrameRefCon;
        if (outputBufferPtr) {
            *outputBufferPtr = CVPixelBufferRetain(imageBuffer);
        }
    } else {
        // Asynchronous mode: push to queue
        [decoder enqueueFrame:imageBuffer pts:presentationTimeStamp];
    }
}

- (void)enqueueFrame:(CVPixelBufferRef)frame pts:(CMTime)pts {
    VTBufferedFrame *bufFrame = [[VTBufferedFrame alloc] init];
    bufFrame.buffer = frame;
    bufFrame.pts = pts;
    
    [_queueLock lock];
    if (_asyncMutableQueue) {
        [_asyncMutableQueue addObject:bufFrame];
    }
    [_queueLock unlock];
}

- (BOOL)createDecompressionSession:(NSError **)error {
    VTDecompressionOutputCallbackRecord callbackRecord;
    callbackRecord.decompressionOutputCallback = outputCallback;
    callbackRecord.decompressionOutputRefCon = (__bridge void *)self;
    
    // Request hardware acceleration for Dolby Vision (and generally preferred)
    NSDictionary *videoDecoderSpecification = @{
        (__bridge NSString *)kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: @YES
    };
    
    // Destination image buffer attributes
    // We want CoreAnimation compatible buffers, ideally NV12 or P010 (handled by VT automatically usually)
    // But setting kCVPixelBufferMetalCompatibilityKey is good practice if we use Metal.
    NSMutableDictionary *destinationImageBufferAttributes = [NSMutableDictionary dictionaryWithDictionary:@{
        (__bridge NSString *)kCVPixelBufferMetalCompatibilityKey: @YES
    }];
    
    // For Dolby Vision Profile 5 (10-bit), request appropriate pixel format
    if (_isDolbyVision && (_dolbyVisionProfile == 5 || _dolbyVisionProfile == 7 || _dolbyVisionProfile == 8)) {
        destinationImageBufferAttributes[(__bridge NSString *)kCVPixelBufferPixelFormatTypeKey] = 
            @(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange);
        NSLog(@"[VTDecoder] Requesting 10-bit pixel format for Dolby Vision");
    }
    
    OSStatus status = VTDecompressionSessionCreate(
        kCFAllocatorDefault,
        _formatDescription,
        (__bridge CFDictionaryRef)videoDecoderSpecification,
        (__bridge CFDictionaryRef)destinationImageBufferAttributes,
        &callbackRecord,
        &_decompressionSession
    );
    
    if (status != noErr) {
        if (error) *error = [NSError errorWithDomain:VTDecoderErrorDomain code:VTDecoderErrorSessionCreationFailed userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"VTDecompressionSessionCreate failed: %d", (int)status]}];
        return NO;
    }
    
    return YES;
}

- (NSTimeInterval)averageDecodeDuration {
    if (_decodeCount == 0) return 0;
    return _totalDecodeTime / _decodeCount;
}

#pragma mark - Decoding

- (CVPixelBufferRef)decodePacket:(AVPacket *)packet error:(NSError **)error {
    if (!_decompressionSession) {
        // Attempt to recreate session if format description is available
        if (_formatDescription) {
             if (![self createDecompressionSession:error]) {
                 return NULL;
             }
        } else {
            if (error) *error = [NSError errorWithDomain:VTDecoderErrorDomain code:VTDecoderErrorSessionNotActive userInfo:@{NSLocalizedDescriptionKey: @"Decompression session not active and cannot be recreated (missing format desc)"}];
            return NULL;
        }
    }
    
    // 1. Create CMBlockBuffer from AVPacket data
    // Safe copy: Allocate new memory and copy data to ensure safety regardless of AVPacket lifetime
    CMBlockBufferRef blockBuffer = NULL;
    OSStatus status = CMBlockBufferCreateWithMemoryBlock(
        kCFAllocatorDefault,
        NULL,
        packet->size,
        kCFAllocatorDefault,
        NULL,
        0,
        packet->size,
        kCMBlockBufferAssureMemoryNowFlag,
        &blockBuffer
    );
    
    if (status == noErr) {
        status = CMBlockBufferReplaceDataBytes(packet->data, blockBuffer, 0, packet->size);
    }
    
    if (status != noErr) {
        if (error) *error = [NSError errorWithDomain:VTDecoderErrorDomain code:VTDecoderErrorBlockBufferCreationFailed userInfo:@{NSLocalizedDescriptionKey: @"CMBlockBufferCreateWithMemoryBlock or Copy failed"}];
        return NULL;
    }
    
    // 2. Create CMSampleBuffer
    CMSampleBufferRef sampleBuffer = NULL;
    size_t sampleSize = packet->size;
    
    // Calculate timing info
    CMSampleTimingInfo timingInfo;
    timingInfo.duration = kCMTimeInvalid; // Decoder infers duration or we don't care for display immediate?
                                          // Better to provide if available (packet->duration)
    
    // Convert PTS and DTS
    CMTime pts = kCMTimeInvalid;
    CMTime dts = kCMTimeInvalid;
    
    if (packet->pts != AV_NOPTS_VALUE) {
        pts = CMTimeMake(packet->pts * _timeBase.num, _timeBase.den);
    }
    if (packet->dts != AV_NOPTS_VALUE) {
        dts = CMTimeMake(packet->dts * _timeBase.num, _timeBase.den);
    } else {
        dts = pts; // Fallback
    }
    
    if (packet->duration > 0) {
        timingInfo.duration = CMTimeMake(packet->duration * _timeBase.num, _timeBase.den);
    }
    timingInfo.presentationTimeStamp = pts;
    timingInfo.decodeTimeStamp = dts;
    
    status = CMSampleBufferCreateReady(
        kCFAllocatorDefault,
        blockBuffer,
        _formatDescription,
        1, 1, &timingInfo,
        1, &sampleSize,
        &sampleBuffer
    );
    
    if (status != noErr) {
        CFRelease(blockBuffer);
        if (error) *error = [NSError errorWithDomain:VTDecoderErrorDomain code:VTDecoderErrorSampleBufferCreationFailed userInfo:@{NSLocalizedDescriptionKey: @"CMSampleBufferCreateReady failed"}];
        return NULL;
    }
    
    // 3. Decode
    CVPixelBufferRef outputPixelBuffer = NULL;
    CFAbsoluteTime startTime = CFAbsoluteTimeGetCurrent();
    VTDecodeFrameFlags flags = 0;
    
    status = VTDecompressionSessionDecodeFrame(
        _decompressionSession,
        sampleBuffer,
        flags,
        &outputPixelBuffer, // sourceFrameRefCon != NULL sets implicit sync mode in callback
        NULL // infoFlagsOut
    );
    
    CFRelease(sampleBuffer);
    CFRelease(blockBuffer);
    
    CFAbsoluteTime duration = CFAbsoluteTimeGetCurrent() - startTime;
    _totalDecodeTime += duration;
    _decodeCount++;
    
    if (status != noErr) {
        if (error) *error = [NSError errorWithDomain:VTDecoderErrorDomain code:VTDecoderErrorDecodeFailed userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"VTDecompressionSessionDecodeFrame failed: %d", (int)status]}];
        // Release potential partial result if any? (likely NULL)
        if (outputPixelBuffer) CVPixelBufferRelease(outputPixelBuffer);
        return NULL;
    }
    
    return outputPixelBuffer; // Accessor (VideoDecoder or caller) is responsible for releasing this Retained buffer
}

- (BOOL)sendPacket:(AVPacket *)packet error:(NSError **)error {
    if (!_decompressionSession) {
         if (_formatDescription) {
             if (![self createDecompressionSession:error]) return NO;
         } else {
             if (error) *error = [NSError errorWithDomain:VTDecoderErrorDomain code:VTDecoderErrorSessionNotActive userInfo:@{NSLocalizedDescriptionKey: @"Session not active"}];
             return NO;
         }
    }
    
    // 1. Create CMBlockBuffer
    CMBlockBufferRef blockBuffer = NULL;
    OSStatus status = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL, packet->size, kCFAllocatorDefault, NULL, 0, packet->size, kCMBlockBufferAssureMemoryNowFlag, &blockBuffer);
    if (status == noErr) status = CMBlockBufferReplaceDataBytes(packet->data, blockBuffer, 0, packet->size);
    if (status != noErr) {
        if (error) *error = [NSError errorWithDomain:VTDecoderErrorDomain code:VTDecoderErrorBlockBufferCreationFailed userInfo:nil];
        return NO;
    }
    
    // 2. Sample Buffer
    CMSampleBufferRef sampleBuffer = NULL;
    size_t sampleSize = packet->size;
    CMSampleTimingInfo timingInfo;
    timingInfo.duration = (packet->duration > 0) ? CMTimeMake(packet->duration * _timeBase.num, _timeBase.den) : kCMTimeInvalid;
    timingInfo.presentationTimeStamp = (packet->pts != AV_NOPTS_VALUE) ? CMTimeMake(packet->pts * _timeBase.num, _timeBase.den) : kCMTimeInvalid;
    timingInfo.decodeTimeStamp = (packet->dts != AV_NOPTS_VALUE) ? CMTimeMake(packet->dts * _timeBase.num, _timeBase.den) : timingInfo.presentationTimeStamp;
    
    status = CMSampleBufferCreateReady(kCFAllocatorDefault, blockBuffer, _formatDescription, 1, 1, &timingInfo, 1, &sampleSize, &sampleBuffer);
    CFRelease(blockBuffer);
    if (status != noErr) {
        if (error) *error = [NSError errorWithDomain:VTDecoderErrorDomain code:VTDecoderErrorSampleBufferCreationFailed userInfo:nil];
        return NO;
    }
    
    // 3. Decode Async
    VTDecodeFrameFlags flags = kVTDecodeFrame_EnableAsynchronousDecompression;
    status = VTDecompressionSessionDecodeFrame(_decompressionSession, sampleBuffer, flags, NULL, NULL);
    CFRelease(sampleBuffer);
    
    if (status != noErr) {
        if (error) *error = [NSError errorWithDomain:VTDecoderErrorDomain code:VTDecoderErrorDecodeFailed userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Async decode failed: %d", (int)status]}];
        return NO;
    }
    return YES;
}

- (CVPixelBufferRef)popFrame:(CMTime *)ptsOut {
    CVPixelBufferRef frame = NULL;
    [_queueLock lock];
    if (_asyncMutableQueue.count > 0) {
        VTBufferedFrame *bufFrame = _asyncMutableQueue.firstObject;
        frame = bufFrame.buffer;
        if (frame) CFRetain(frame); // Retain for caller
        
        if (ptsOut) *ptsOut = bufFrame.pts;
        
        [_asyncMutableQueue removeObjectAtIndex:0];
    }
    [_queueLock unlock];
    return frame;
}

- (void)flush {
    if (_decompressionSession) {
        VTDecompressionSessionFinishDelayedFrames(_decompressionSession);
        VTDecompressionSessionWaitForAsynchronousFrames(_decompressionSession);
    }
    [_queueLock lock];
    [_asyncMutableQueue removeAllObjects];
    [_queueLock unlock];
}

@end
