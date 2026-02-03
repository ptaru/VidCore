//
//  SystemAudioRenderer.swift
//  VidCore
//
//  AVSampleBufferAudioRenderer wrapper for system-timed audio playback
//

import AVFoundation
import CoreMedia
import Foundation

public final class SystemAudioRenderer: AudioRendering, @unchecked Sendable {
  public static var isSupportedInCurrentProcess: Bool {
    // AVSampleBufferAudioRenderer is not supported in app extensions (e.g. QuickLook).
    Bundle.main.bundleURL.pathExtension != "appex"
  }

  public static var isForceFallbackEnabled: Bool {
    let value = ProcessInfo.processInfo.environment["VIDCORE_FORCE_AUDIO_ENGINE"] ?? "0"
    return value == "1" || value.lowercased() == "true"
  }

  public let renderer: AVSampleBufferAudioRenderer?
  public let isEnabled: Bool

  private var cachedFormatDescription: CMAudioFormatDescription?
  private var cachedFormatKey: String?
  private let readinessQueue = DispatchQueue(label: "VidCore.SystemAudioRenderer.Readiness")
  private let readinessLock = NSLock()
  private var readinessWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
  private var isRequestingReadiness: Bool = false
  private let readinessTimeoutNanos: UInt64 = 250_000_000

  public init(enabled: Bool = SystemAudioRenderer.isSupportedInCurrentProcess) {
    self.isEnabled = enabled
    self.renderer = enabled ? AVSampleBufferAudioRenderer() : nil
  }

  public var isReadyForMoreMediaData: Bool {
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
        readinessLock.lock()
        readinessWaiters[waiterID] = continuation
        let shouldStart = !isRequestingReadiness
        if shouldStart {
          isRequestingReadiness = true
        }
        readinessLock.unlock()

        Task {
          try? await Task.sleep(nanoseconds: readinessTimeoutNanos)
          var shouldStop = false
          var waiter: CheckedContinuation<Void, Never>?
          readinessLock.lock()
          waiter = readinessWaiters.removeValue(forKey: waiterID)
          shouldStop = readinessWaiters.isEmpty && isRequestingReadiness
          if shouldStop {
            isRequestingReadiness = false
          }
          readinessLock.unlock()
          if shouldStop {
            renderer.stopRequestingMediaData()
          }
          waiter?.resume()
        }

        if shouldStart {
          renderer.requestMediaDataWhenReady(on: readinessQueue) { [weak self, weak renderer] in
            guard let self, let renderer else { return }
            guard renderer.isReadyForMoreMediaData else { return }

            renderer.stopRequestingMediaData()

            self.readinessLock.lock()
            let waiters = self.readinessWaiters.values
            self.readinessWaiters.removeAll()
            self.isRequestingReadiness = false
            self.readinessLock.unlock()

            for waiter in waiters {
              waiter.resume()
            }
          }
        }
      }
    } onCancel: {
      readinessLock.lock()
      let waiter = readinessWaiters.removeValue(forKey: waiterID)
      let shouldStop = readinessWaiters.isEmpty && isRequestingReadiness
      if shouldStop {
        isRequestingReadiness = false
      }
      readinessLock.unlock()

      if shouldStop {
        renderer.stopRequestingMediaData()
      }

      waiter?.resume()
    }
  }

  public func flush() {
    renderer?.flush()
  }

  public func enqueue(_ buffer: AVAudioPCMBuffer, pts: Double, volume: Float = 1.0) {
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
    let key = "\(format.sampleRate)-\(format.channelCount)-\(format.commonFormat.rawValue)-\(format.isInterleaved)"
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

  public func play(rate: Double) {
    // System audio renderer follows the synchronizer timebase.
  }

  public func pause() {
    // System audio renderer follows the synchronizer timebase.
  }

  public func seek(to seconds: Double) {
    // System audio renderer follows the synchronizer timebase.
  }
}
