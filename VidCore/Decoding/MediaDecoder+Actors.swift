//
//  MediaDecoder+Actors.swift
//  VidCore
//

import AVFoundation
import Foundation

/// Actor managing the FFmpegDemuxer to ensure thread safety
actor DemuxerActor {
    private let demuxer: FFmpegDemuxer

    init(demuxer: FFmpegDemuxer) {
        self.demuxer = demuxer
    }

    func demuxNextPacket() -> FFmpegDemuxerPacket? {
        return demuxer.demuxNextPacket()
    }

    func seek(toKeyframe seconds: Double) -> Bool {
        return demuxer.seek(toKeyframe: seconds)
    }

    func collectPackets(until seconds: Double) -> [FFmpegDemuxerPacket]? {
        return demuxer.collectPackets(until: seconds)
    }

    func extractCoverImage() -> Data? {
        return demuxer.extractCoverImage()
    }

    func close() {
        demuxer.close()
    }

    func requestAbortIO() {
        demuxer.requestAbortIO()
    }

    func clearAbortIO() {
        demuxer.clearAbortIO()
    }

    func popQueuedAudioPacket() -> FFmpegDemuxerPacket? {
        return demuxer.popQueuedAudioPacket()
    }

    // Audio/Subtitle Track Helpers

    func getAudioTracks() -> [FFmpegAudioTrackInfo]? {
        return demuxer.getAudioTracks()
    }

    func selectedAudioStreamIndex() -> Int32 {
        return demuxer.selectedAudioStreamIndex()
    }

    func selectAudioStream(_ streamIndex: Int32) -> Bool {
        return demuxer.selectAudioStream(streamIndex)
    }

    func getAudioDecoderConfig(forStream streamIndex: Int32) -> [String: Any]? {
        return demuxer.getAudioDecoderConfig(forStream: streamIndex)
    }

    func getSubtitleTracks() -> [FFmpegSubtitleTrackInfo]? {
        return demuxer.getSubtitleTracks()
    }

    func selectedSubtitleStreamIndex() -> Int32 {
        return demuxer.selectedSubtitleStreamIndex()
    }

    func selectSubtitleStream(_ streamIndex: Int32) -> Bool {
        return demuxer.selectSubtitleStream(streamIndex)
    }

    func getSubtitleDecoderConfig(forStream streamIndex: Int32) -> [String: Any]? {
        return demuxer.getSubtitleDecoderConfig(forStream: streamIndex)
    }

    func getSampleBufferBuilderConfig() -> [String: Any]? {
        return demuxer.getSampleBufferBuilderConfig()
    }
}

/// Actor managing the FFmpegDecoder to ensure thread safety
actor DecoderActor {
    private let decoder: FFmpegDecoder

    init(decoder: FFmpegDecoder) {
        self.decoder = decoder
    }

    func decodeVideoPacket(withAllFrames packet: FFmpegDemuxerPacket) -> [FFmpegVideoFrame]? {
        return decoder.decodeVideoPacket(withAllFrames: packet)
    }

    func decodeAudioPacket(withAllFrames packet: FFmpegDemuxerPacket) -> [FFmpegAudioFrame]? {
        return decoder.decodeAudioPacket(withAllFrames: packet)
    }

    func decodeSubtitlePacket(_ packet: FFmpegDemuxerPacket) -> FFmpegSubtitleFrame? {
        return decoder.decodeSubtitlePacket(packet)
    }

    func flushMediaDecoder() {
        decoder.flushMediaDecoder()
    }

    func flushAudioDecoder() {
        decoder.flushAudioDecoder()
    }

    func flushCodecBuffers() {
        decoder.flushCodecBuffers()
    }

    func setFastSeekDecodingEnabled(_ enabled: Bool) {
        decoder.setFastSeekDecodingEnabled(enabled)
    }

    func drainVideoFrame() -> FFmpegVideoFrame? {
        return decoder.drainVideoFrame()
    }

    func drainAudioFrame() -> FFmpegAudioFrame? {
        return decoder.drainAudioFrame()
    }

    func switchAudioStream(_ config: [String: Any]) -> Bool {
        return decoder.switchAudioStream(config)
    }

    func switchSubtitleStream(_ config: [String: Any]) -> Bool {
        return decoder.switchSubtitleStream(config)
    }

    func close() {
        decoder.close()
    }

    func getVideoInfo() -> FFmpegVideoInfo? {
        return decoder.getVideoInfo()
    }
}
