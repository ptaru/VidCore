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
  private var decoder: VideoDecoder?
  private var packetQueue: PacketQueue
  private weak var renderer: (any VideoRendererTarget)?
  private var audioOutput: AudioRendering
  private var volume: Double = 1.0

  private var demuxTask: Task<Void, Never>?
  private var decodeTask: Task<Void, Never>?
  private var hasSignaledAudio = false

  init(
    decoder: VideoDecoder?,
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

  func updateDecoder(_ decoder: VideoDecoder?) {
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
    guard let decoder else { return nil }

    while !Task.isCancelled {
      guard let packet = await decoder.demuxNextPacket() else { break }
      let frames = await decoder.decodePacket(packet)
      if let videoFrame = frames.compactMap({ frame -> VideoFrame? in
        if case .video(let vf) = frame { return vf }
        return nil
      }).first {
        return videoFrame
      }
    }

    return nil
  }

  private func runDemuxLoop() async {
    guard let decoder else { return }

    while !Task.isCancelled {
      if await packetQueue.suspended {
        try? await Task.sleep(nanoseconds: 10_000_000)  // 10ms
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
        try? await Task.sleep(nanoseconds: 10_000_000)  // 10ms
        continue
      }

      guard let packet = await packetQueue.pop() else {
        if await packetQueue.suspended {
          continue
        }

        await decoder.flushVideoDecoder()
        await decoder.flushAudioDecoder()

        while !Task.isCancelled {
          guard let frame = await decoder.drainVideoFrame() else {
            break
          }
          if let readinessAwaiter = renderer as? MediaDataReadinessAwaiting {
            await readinessAwaiter.waitUntilReady()
          }
          guard !Task.isCancelled else { break }
          await renderer?.enqueue(frame)
          await delegate?.workerDidRenderVideoFrame(frame)
          await delegate?.workerRefreshDebugStats(videoPTS: frame.presentationTime)
        }

        while !Task.isCancelled {
          guard let (buffer, pts) = await decoder.drainAudioFrame() else {
            break
          }
          guard audioOutput.isEnabled else { break }
          await audioOutput.waitUntilReady()
          if !Task.isCancelled {
            audioOutput.enqueue(buffer, pts: pts, volume: Float(volume))
            if !hasSignaledAudio {
              hasSignaledAudio = true
              await delegate?.workerDidDetectAudio()
            }
            await delegate?.workerRefreshDebugStats(videoPTS: nil)
          }
        }

        await delegate?.workerDidFinishStream()
        break
      }

      guard !Task.isCancelled else { break }

      let decodedFrames = await decoder.decodePacket(packet)
      for frame in decodedFrames {
        switch frame {
        case .video(let videoFrame):
          if let readinessAwaiter = renderer as? MediaDataReadinessAwaiting {
            await readinessAwaiter.waitUntilReady()
          }
          guard !Task.isCancelled else { break }
          await renderer?.enqueue(videoFrame)
          await delegate?.workerDidRenderVideoFrame(videoFrame)
          await delegate?.workerRefreshDebugStats(videoPTS: videoFrame.presentationTime)
        case .audio(let buffer, let pts):
          guard audioOutput.isEnabled else { break }
          await audioOutput.waitUntilReady()
          if !Task.isCancelled {
            audioOutput.enqueue(buffer, pts: pts, volume: Float(volume))
            if !hasSignaledAudio {
              hasSignaledAudio = true
              await delegate?.workerDidDetectAudio()
            }
            await delegate?.workerRefreshDebugStats(videoPTS: nil)
          }
        case .subtitle(let subtitleFrame):
          await delegate?.workerDidDecodeSubtitle(subtitleFrame)
        }
      }
    }
  }
}
