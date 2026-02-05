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

  private var cachedFormatDescription: CMAudioFormatDescription?
  private var cachedFormatKey: String?
  private var readinessWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
  private var isRequestingReadiness: Bool = false
  private let readinessTimeoutNanos: UInt64 = 250_000_000

  public init(enabled: Bool = SystemAudioRenderer.isSupportedInCurrentProcess) {
    self.isEnabled = enabled
    self.renderer = enabled ? AVSampleBufferAudioRenderer() : nil
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

  public nonisolated func flush() async {
    renderer?.flush()
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

    guard let formatDescription = makeFormatDescription(for: buffer.format) else { return }

    let timeScale = CMTimeScale(max(1, Int32(buffer.format.sampleRate)))
    let presentationTime = CMTime(
      seconds: pts,
      preferredTimescale: timeScale
    )

    var blockBuffer: CMBlockBuffer?
    let bbStatus = CMBlockBufferCreateEmpty(
      allocator: kCFAllocatorDefault,
      capacity: 0,
      flags: 0,
      blockBufferOut: &blockBuffer
    )
    guard bbStatus == noErr, let bb = blockBuffer else { return }

    var sampleBuffer: CMSampleBuffer?
    let status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
      allocator: kCFAllocatorDefault,
      dataBuffer: bb,
      formatDescription: formatDescription,
      sampleCount: CMItemCount(buffer.frameLength),
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
      bufferList: buffer.audioBufferList
    )
    guard copyStatus == noErr else { return }

    renderer?.enqueue(sbuf)
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
      guard status == noErr else { return nil }
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
      guard status == noErr else { return nil }
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
