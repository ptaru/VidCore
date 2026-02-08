//
//  PlaybackWorker.swift
//  VidCore
//
//  Background playback pipeline (demux/decode/render) separated from MainActor.
//

import Foundation

@MainActor
protocol PlaybackWorkerDelegate: AnyObject {
  func workerDidRenderVideoFrame(_ frame: VideoFrame)
  func workerDidDecodeSubtitle(_ subtitle: SubtitleFrame)
  func workerDidDetectAudio()
  func workerDidFinishStream()
  func workerRefreshDebugStats(videoPTS: Double?) async
}

actor PlaybackWorker {
  private weak var delegate: (any PlaybackWorkerDelegate)?
  private var decoder: MediaDecoder?
  private var packetQueue: PacketQueue
  private weak var renderer: (any VideoRendererTarget)?
  private var audioOutput: AudioRendering
  private var volume: Double = 1.0

  private var demuxTask: Task<Void, Never>?
  private var decodeTask: Task<Void, Never>?
  private var hasSignaledAudio = false

  init(
    decoder: MediaDecoder?,
    packetQueue: PacketQueue,
    renderer: (any VideoRendererTarget)?,
    audioOutput: AudioRendering,
    delegate: any PlaybackWorkerDelegate
  ) {
    self.decoder = decoder
    self.packetQueue = packetQueue
    self.renderer = renderer
    self.audioOutput = audioOutput
    self.delegate = delegate
  }

  func updateDecoder(_ decoder: MediaDecoder?) {
    self.decoder = decoder
    hasSignaledAudio = false
  }

  func updatePacketQueue(_ packetQueue: PacketQueue) {
    self.packetQueue = packetQueue
  }

  func updateRenderer(_ renderer: (any VideoRendererTarget)?) {
    self.renderer = renderer
  }

  func updateVolume(_ volume: Double) {
    self.volume = volume
    audioOutput.setVolume(Float(volume))
  }

  func start() {
    if demuxTask == nil {
      demuxTask = Task { [weak self] in
        await self?.runDemuxLoop()
      }
    }

    if decodeTask == nil {
      decodeTask = Task { [weak self] in
        await self?.runDecodeLoop()
      }
    }
  }

  func stop() async {
    demuxTask?.cancel()
    decodeTask?.cancel()

    // Wake up any blocked producers/consumers so they can observe cancellation.
    await packetQueue.suspend()

    await demuxTask?.value
    await decodeTask?.value

    demuxTask = nil
    decodeTask = nil
  }

  func primeFirstVideoFrame() async -> VideoFrame? {
    guard let decoder, decoder.videoInfo.width > 0, decoder.videoInfo.height > 0 else { return nil }

    // Simplified prime loop
    while !Task.isCancelled {
      guard let packet = await decoder.demuxNextPacket() else { break }
      let frames = await decoder.decodePacket(packet)
      // Check for video frame
      for case .video(let vf) in frames {
          return vf
      }
    }
    return nil
  }

  // MARK: - Loops

  private func runDemuxLoop() async {
    guard let decoder else { return }

    while !Task.isCancelled {
      if await packetQueue.suspended {
        await packetQueue.waitUntilResumed()
        continue
      }

      guard let packet = await decoder.demuxNextPacket() else {
        await packetQueue.close()
        break
      }

      await packetQueue.push(packet)
    }
  }

  private func runDecodeLoop() async {
    guard let decoder else { return }

    while !Task.isCancelled {
      if await packetQueue.suspended {
        await packetQueue.waitUntilResumed()
        continue
      }

      guard let packet = await packetQueue.pop() else {
         if await packetQueue.suspended { continue }
         
         // Queue closed - Drain leftovers
         await drainDecoder(decoder)
         break
      }

      // Process normal packet
      await processPacket(packet, decoder: decoder)
    }
  }
  
  // MARK: - Helpers
  
  private func processPacket(_ packet: FFmpegPacketData, decoder: MediaDecoder) async {
      let decodedFrames = await decoder.decodePacket(packet)
      for frame in decodedFrames {
        switch frame {
        case .video(let videoFrame):
          await processVideoFrame(videoFrame)
        case .audio(let buffer, let pts):
          await processAudioFrame(buffer, pts: pts)
        case .subtitle(let subtitleFrame):
          await delegate?.workerDidDecodeSubtitle(subtitleFrame)
        }
      }
  }
  
  private func drainDecoder(_ decoder: MediaDecoder) async {
      await decoder.flushMediaDecoder()
      await decoder.flushAudioDecoder()
      
      while !Task.isCancelled {
          guard let frame = await decoder.drainVideoFrame() else { break }
          await processVideoFrame(frame)
      }
      
      while !Task.isCancelled {
          guard let (buffer, pts) = await decoder.drainAudioFrame() else { break }
          await processAudioFrame(buffer, pts: pts)
      }
      
      await delegate?.workerDidFinishStream()
  }
  
  private func processVideoFrame(_ frame: VideoFrame) async {
      if let readinessAwaiter = renderer as? MediaDataReadinessAwaiting {
        await readinessAwaiter.waitUntilReady()
      }
      guard !Task.isCancelled else { return }
      
      await renderer?.enqueue(frame)
      await delegate?.workerDidRenderVideoFrame(frame)
      await delegate?.workerRefreshDebugStats(videoPTS: frame.presentationTime)
  }
  
  private func processAudioFrame(_ buffer: AVAudioPCMBuffer, pts: Double) async {
      guard audioOutput.isEnabled else { return }
      await audioOutput.waitUntilReady()
      
      guard !Task.isCancelled else { return }
      
      await audioOutput.enqueue(buffer, pts: pts, volume: Float(volume))
      if !hasSignaledAudio {
        hasSignaledAudio = true
        await delegate?.workerDidDetectAudio()
      }
      await delegate?.workerRefreshDebugStats(videoPTS: nil)
  }
}
