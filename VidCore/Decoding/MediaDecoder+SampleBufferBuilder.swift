//
//  MediaDecoder+SampleBufferBuilder.swift
//  VidCore
//

import Foundation

/// Convert FFmpegDemuxer's config dictionary to SampleBufferBuilderConfig.
func createSampleBufferBuilder(from config: [String: Any]) throws -> SampleBufferBuilder {
    guard let codecNum = config["codec"] as? NSNumber,
        let width = config["width"] as? NSNumber,
        let height = config["height"] as? NSNumber,
        let extradata = config["extradata"] as? Data,
        let timeBaseNum = config["timeBaseNum"] as? NSNumber,
        let timeBaseDen = config["timeBaseDen"] as? NSNumber
    else {
        throw SampleBufferBuilderError.noExtradata
    }

    let codec: SampleBufferBuilderCodec = codecNum.intValue == 0 ? .hevc : .h264

    let sbConfig = SampleBufferBuilderConfig(
        codec: codec,
        width: width.int32Value,
        height: height.int32Value,
        extradata: extradata,
        timeBaseNum: timeBaseNum.int32Value,
        timeBaseDen: timeBaseDen.int32Value,
        colorPrimaries: (config["colorPrimaries"] as? NSNumber)?.int32Value ?? 0,
        colorTransfer: (config["colorTransfer"] as? NSNumber)?.int32Value ?? 0,
        colorSpace: (config["colorSpace"] as? NSNumber)?.int32Value ?? 0,
        dolbyVisionConfig: config["dolbyVisionConfig"] as? Data
    )

    return try SampleBufferBuilder(config: sbConfig)
}
