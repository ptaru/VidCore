//
//  SystemAudioRenderer.swift
//  VidCore
//
//  AVSampleBufferAudioRenderer wrapper for system-timed audio playback
//

import AVFoundation
import CoreMedia
import Foundation

public actor SystemAudioRenderer: AudioRendering {
  public nonisolated static var isSupportedInCurrentProcess: Bool {
    // AVSampleBufferAudioRenderer is not supported in app extensions (e.g. QuickLook).
    Bundle.main.bundleURL.pathExtension != "appex"
  }

  public nonisolated static var isForceFallbackEnabled: Bool {
    let value = ProcessInfo.processInfo.environment["VIDCORE_FORCE_AUDIO_ENGINE"] ?? "0"
    return value == "1" || value.lowercased() == "true"
  }

  public nonisolated let renderer: AVSampleBufferAudioRenderer?
  public nonisolated let isEnabled: Bool
  private let outputChannelCount: AVAudioChannelCount
  private var hasLoggedOutputChannelWarning: Bool = false

  private var cachedFormatDescription: CMAudioFormatDescription?
  private var cachedFormatKey: String?
  private var readinessWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
  private var isRequestingReadiness: Bool = false
  private let readinessTimeoutNanos: UInt64 = 250_000_000
  private let minCoalesceFrames: AVAudioFrameCount = 1024
  private let maxCoalesceFrames: AVAudioFrameCount = 4096
  private var pendingBuffer: AVAudioPCMBuffer?
  private var pendingPTS: Double?
  private var pendingFormatKey: String?

  public init(enabled: Bool = SystemAudioRenderer.isSupportedInCurrentProcess) {
    self.isEnabled = enabled
    self.renderer = enabled ? AVSampleBufferAudioRenderer() : nil
    let engine = AVAudioEngine()
    self.outputChannelCount = engine.outputNode.outputFormat(forBus: 0).channelCount
  }

  public nonisolated var isReadyForMoreMediaData: Bool {
    renderer?.isReadyForMoreMediaData ?? false
  }

  public func waitUntilReady() async {
    guard let renderer else { return }
    if renderer.isReadyForMoreMediaData {
      return
    }

    let waiterID = UUID()
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        readinessWaiters[waiterID] = continuation
        let shouldStart = !isRequestingReadiness
        if shouldStart {
          isRequestingReadiness = true
        }

        Task {
          try? await Task.sleep(nanoseconds: readinessTimeoutNanos)
          var shouldStop = false
          var waiter: CheckedContinuation<Void, Never>?
          self.timeoutWaiter(waiterID: waiterID) { stop, w in
            shouldStop = stop
            waiter = w
          }
          if shouldStop {
            renderer.stopRequestingMediaData()
          }
          waiter?.resume()
        }

        if shouldStart {
          renderer.requestMediaDataWhenReady(on: DispatchQueue.global()) { [weak self] in
            guard let self, let renderer = self.renderer else { return }
            guard renderer.isReadyForMoreMediaData else { return }

            renderer.stopRequestingMediaData()

            Task {
              await self.resumeAllWaiters()
            }
          }
        }
      }
    } onCancel: {
      Task {
        await self.cancelWaiter(waiterID: waiterID, renderer: renderer)
      }
    }
  }

  private func timeoutWaiter(
    waiterID: UUID, completion: (Bool, CheckedContinuation<Void, Never>?) -> Void
  ) {
    let waiter = readinessWaiters.removeValue(forKey: waiterID)
    let shouldStop = readinessWaiters.isEmpty && isRequestingReadiness
    if shouldStop {
      isRequestingReadiness = false
    }
    completion(shouldStop, waiter)
  }

  private func resumeAllWaiters() {
    let waiters = readinessWaiters.values
    readinessWaiters.removeAll()
    isRequestingReadiness = false

    for waiter in waiters {
      waiter.resume()
    }
  }

  private func cancelWaiter(waiterID: UUID, renderer: AVSampleBufferAudioRenderer) {
    let waiter = readinessWaiters.removeValue(forKey: waiterID)
    let shouldStop = readinessWaiters.isEmpty && isRequestingReadiness
    if shouldStop {
      isRequestingReadiness = false
    }

    if shouldStop {
      renderer.stopRequestingMediaData()
    }

    waiter?.resume()
  }

  public func flush() async {
    renderer?.flush()
    pendingBuffer = nil
    pendingPTS = nil
    pendingFormatKey = nil
    resumeAllWaiters()
  }

  public nonisolated func enqueue(_ buffer: AVAudioPCMBuffer, pts: Double, volume: Float = 1.0) {
    Task {
      await _enqueue(buffer, pts: pts, volume: volume)
    }
  }

  private func _enqueue(_ buffer: AVAudioPCMBuffer, pts: Double, volume: Float) {
    let clampedVolume = max(0.0, min(volume, 1.0))
    if clampedVolume != 1.0 {
      if let channels = buffer.floatChannelData {
        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        for ch in 0..<channelCount {
          let ptr = channels[ch]
          for i in 0..<frameCount {
            ptr[i] *= clampedVolume
          }
        }
      }
    }

    let bufferFormatKey = formatKey(for: buffer.format)
    if buffer.frameLength < minCoalesceFrames {
      if pendingFormatKey != bufferFormatKey {
        flushPendingIfNeeded()
      }
      if pendingBuffer == nil {
        pendingBuffer = makePendingBuffer(format: buffer.format)
        pendingFormatKey = bufferFormatKey
        pendingPTS = pts
      }

      if let pendingBuffer = pendingBuffer {
        if let pendingPTS = pendingPTS {
          let expectedNextPTS =
            pendingPTS
            + Double(pendingBuffer.frameLength) / buffer.format.sampleRate
          let ptsTolerance = max(2.0 / buffer.format.sampleRate, 0.001)
          if abs(pts - expectedNextPTS) > ptsTolerance {
            enqueueDirect(pendingBuffer, pts: pendingPTS)
            self.pendingBuffer = makePendingBuffer(format: buffer.format)
            self.pendingPTS = pts
            self.pendingFormatKey = bufferFormatKey
          }
        }

        if append(buffer, to: pendingBuffer) {
          if pendingBuffer.frameLength >= minCoalesceFrames
            || pendingBuffer.frameLength >= maxCoalesceFrames
          {
            if let pendingPTS = pendingPTS {
              enqueueDirect(pendingBuffer, pts: pendingPTS)
            }
            self.pendingBuffer = nil
            self.pendingPTS = nil
            self.pendingFormatKey = nil
          }
          return
        } else {
          if let pendingPTS = pendingPTS {
            enqueueDirect(pendingBuffer, pts: pendingPTS)
          }
          self.pendingBuffer = nil
          self.pendingPTS = nil
          self.pendingFormatKey = nil
        }
      }
    } else {
      flushPendingIfNeeded()
    }

    enqueueDirect(buffer, pts: pts)
  }

  private func enqueueDirect(_ buffer: AVAudioPCMBuffer, pts: Double) {
    let renderBuffer = makeSystemRenderBuffer(buffer)
    guard let formatDescription = makeFormatDescription(for: renderBuffer.format) else { return }

    let timeScale = CMTimeScale(max(1, Int32(renderBuffer.format.sampleRate)))
    let presentationTime = CMTime(
      seconds: pts,
      preferredTimescale: timeScale
    )

    var sampleBuffer: CMSampleBuffer?
    let status = CMAudioSampleBufferCreateWithPacketDescriptions(
      allocator: kCFAllocatorDefault,
      dataBuffer: nil,
      dataReady: false,
      makeDataReadyCallback: nil,
      refcon: nil,
      formatDescription: formatDescription,
      sampleCount: CMItemCount(renderBuffer.frameLength),
      presentationTimeStamp: presentationTime,
      packetDescriptions: nil,
      sampleBufferOut: &sampleBuffer
    )

    guard status == noErr, let sbuf = sampleBuffer else { return }

    // Copy audio data into an owned CMBlockBuffer so the CMSampleBuffer is self-contained.
    let copyStatus = CMSampleBufferSetDataBufferFromAudioBufferList(
      sbuf,
      blockBufferAllocator: kCFAllocatorDefault,
      blockBufferMemoryAllocator: kCFAllocatorDefault,
      flags: 0,
      bufferList: renderBuffer.audioBufferList
    )
    guard copyStatus == noErr else { return }

    let readyStatus = CMSampleBufferSetDataReady(sbuf)
    guard readyStatus == noErr else { return }

    renderer?.enqueue(sbuf)
  }

  private func flushPendingIfNeeded() {
    if let pendingBuffer = pendingBuffer, let pendingPTS = pendingPTS {
      enqueueDirect(pendingBuffer, pts: pendingPTS)
    }
    pendingBuffer = nil
    pendingPTS = nil
    pendingFormatKey = nil
  }

  private func makePendingBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer? {
    AVAudioPCMBuffer(pcmFormat: format, frameCapacity: maxCoalesceFrames)
  }

  private func append(_ src: AVAudioPCMBuffer, to dst: AVAudioPCMBuffer) -> Bool {
    guard formatsMatch(src.format, dst.format) else { return false }
    let totalFrames = dst.frameLength + src.frameLength
    guard totalFrames <= dst.frameCapacity else { return false }

    let bytesPerFrame = Int(src.format.streamDescription.pointee.mBytesPerFrame)
    let dstOffsetBytes = Int(dst.frameLength) * bytesPerFrame
    let srcBytes = Int(src.frameLength) * bytesPerFrame

    let srcBuffers = UnsafeMutableAudioBufferListPointer(
      UnsafeMutablePointer(mutating: src.audioBufferList)
    )
    let dstBuffers = UnsafeMutableAudioBufferListPointer(dst.mutableAudioBufferList)
    guard srcBuffers.count == dstBuffers.count else { return false }

    for idx in 0..<srcBuffers.count {
      let srcBuffer = srcBuffers[idx]
      let dstBuffer = dstBuffers[idx]
      guard let srcData = srcBuffer.mData, let dstData = dstBuffer.mData else { return false }
      memcpy(dstData.advanced(by: dstOffsetBytes), srcData, srcBytes)
    }

    dst.frameLength = totalFrames
    return true
  }

  private func makeSystemRenderBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
    let format = buffer.format
    guard let channels = buffer.floatChannelData else { return buffer }

    // Use Float32 Interleaved for better quality and format compatibility
    let channelLayout = format.channelLayout
    let interleavedFormat: AVAudioFormat?
    if let channelLayout {
      interleavedFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: format.sampleRate,
        interleaved: true,
        channelLayout: channelLayout
      )
    } else {
      interleavedFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: format.sampleRate,
        channels: format.channelCount,
        interleaved: true
      )
    }

    guard let interleavedFormat else { return buffer }

    guard
      let interleavedBuffer = AVAudioPCMBuffer(
        pcmFormat: interleavedFormat,
        frameCapacity: buffer.frameCapacity
      )
    else {
      return buffer
    }

    interleavedBuffer.frameLength = buffer.frameLength

    let channelCount = Int(format.channelCount)
    let frameCount = Int(buffer.frameLength)
    let dstAudioBuffer = interleavedBuffer.mutableAudioBufferList.pointee.mBuffers
    guard let dstData = dstAudioBuffer.mData else { return buffer }

    // Bind to Float instead of Int16
    let dst = dstData.bindMemory(to: Float.self, capacity: frameCount * channelCount)

    // Manual interleaving loop (Planar Float32 -> Interleaved Float32)
    // Optional: vDSP could be used here, but this is explicit and safe.
    for frame in 0..<frameCount {
      let base = frame * channelCount
      for ch in 0..<channelCount {
        let sample = channels[ch][frame]
        // No scaling needed for Float32, just clamp for safety (though not strictly required if source is trusted)
        dst[base + ch] = sample
      }
    }

    return interleavedBuffer
  }

  private func formatKey(for format: AVAudioFormat) -> String {
    "\(format.sampleRate)-\(format.channelCount)-\(format.commonFormat.rawValue)-\(format.isInterleaved)"
  }

  private func formatsMatch(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
    lhs.sampleRate == rhs.sampleRate
      && lhs.channelCount == rhs.channelCount
      && lhs.commonFormat == rhs.commonFormat
      && lhs.isInterleaved == rhs.isInterleaved
  }

  private func makeFormatDescription(for format: AVAudioFormat) -> CMAudioFormatDescription? {
    guard isEnabled else { return nil }
    let key =
      "\(format.sampleRate)-\(format.channelCount)-\(format.commonFormat.rawValue)-\(format.isInterleaved)"
    if key == cachedFormatKey, let cached = cachedFormatDescription {
      return cached
    }

    let asbd = format.streamDescription.pointee
    var desc: CMAudioFormatDescription?

    if let layout = format.channelLayout?.layout.pointee {
      var asbdCopy = asbd
      var layoutCopy = layout
      let status = CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        asbd: &asbdCopy,
        layoutSize: MemoryLayout<AudioChannelLayout>.size,
        layout: &layoutCopy,
        magicCookieSize: 0,
        magicCookie: nil,
        extensions: nil,
        formatDescriptionOut: &desc
      )
      guard status == noErr else {
        return nil
      }
    } else {
      var asbdCopy = asbd
      let status = CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        asbd: &asbdCopy,
        layoutSize: 0,
        layout: nil,
        magicCookieSize: 0,
        magicCookie: nil,
        extensions: nil,
        formatDescriptionOut: &desc
      )
      guard status == noErr else {
        return nil
      }
    }

    cachedFormatKey = key
    cachedFormatDescription = desc
    return desc
  }

  public nonisolated func setPlaybackState(isPlaying: Bool, rate: Double) {
    // System audio renderer follows the synchronizer timebase.
    // State is managed externally by PlaybackClock.
  }
}
