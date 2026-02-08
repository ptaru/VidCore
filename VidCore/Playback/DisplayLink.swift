//
//  DisplayLink.swift
//  VidCore
//
//  Progress tracking synchronized with display VSync using CADisplayLink
//

import Foundation
import QuartzCore

#if os(macOS)
    import AppKit
#endif

/// A source that can provide a `CADisplayLink` for synchronized updates.
///
/// On macOS 14+, `CADisplayLink` is obtained from AppKit objects like `NSView`, `NSWindow`, or `NSScreen`
/// to ensure synchronization with the specific display they are located on.
@MainActor
public protocol DisplayLinkSource: AnyObject {
    #if os(macOS)
        /// Creates a display link for the source.
        /// - Parameters:
        ///   - target: The object that receives the display link notifications.
        ///   - selector: The selector to call on the target for each VSync.
        func displayLink(target: Any, selector: Selector) -> CADisplayLink
    #endif
}

#if os(macOS)
    extension NSScreen: DisplayLinkSource {}
    extension NSWindow: DisplayLinkSource {}
    extension NSView: DisplayLinkSource {}
#endif

/// A helper class that wraps CADisplayLink to provide VSync-synchronized updates.
@MainActor
public final class DisplayLink {
    private var displayLink: CADisplayLink?
    private let onUpdate: () -> Void
    private weak var source: DisplayLinkSource?
    private var isRunning = false
    private var preferredFrameRate: Double?

    /// Creates a new display link instance.
    /// - Parameter onUpdate: A block to execute on each display VSync.
    public init(onUpdate: @escaping () -> Void) {
        self.onUpdate = onUpdate
    }

    /// Sets the source for the display link.
    ///
    /// If the display link is already running, it will automatically restart using the new source
    /// to ensure synchronization with the correct display.
    ///
    /// - Parameter source: The source (e.g., an `NSView` or `NSWindow`) to obtain the display link from.
    public func setSource(_ source: DisplayLinkSource?) {
        self.source = source
        if isRunning {
            stop()
            start()
        }
    }

    /// Sets a preferred frame rate for the display link when supported.
    /// Pass nil to let the system choose.
    public func setPreferredFrameRate(_ fps: Double?) {
        preferredFrameRate = fps
        applyPreferredFrameRate()
    }

    /// Start the display link.
    public func start() {
        guard displayLink == nil else { return }
        isRunning = true

        #if os(macOS)
            if let sourceDisplayLink = source?.displayLink(
                target: self, selector: #selector(handleUpdate))
            {
                self.displayLink = sourceDisplayLink
            } else {
                // Fallback to NSScreen.main if no source or source fails
                self.displayLink = NSScreen.main?.displayLink(
                    target: self, selector: #selector(handleUpdate))
            }
        #else
            self.displayLink = CADisplayLink(target: self, selector: #selector(handleUpdate))
        #endif

        applyPreferredFrameRate()
        displayLink?.add(to: .main, forMode: .common)
    }

    /// Stop the display link.
    public func stop() {
        isRunning = false
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func handleUpdate() {
        onUpdate()
    }

    private func applyPreferredFrameRate() {
        guard let displayLink = displayLink else { return }
        let fps = preferredFrameRate ?? 0

        if #available(macOS 14.0, *) {
            let fpsFloat = Float(fps)
            if fpsFloat > 0 {
                displayLink.preferredFrameRateRange = CAFrameRateRange(
                    minimum: fpsFloat,
                    maximum: fpsFloat,
                    preferred: fpsFloat
                )
            } else {
                displayLink.preferredFrameRateRange = CAFrameRateRange(
                    minimum: 0,
                    maximum: 0,
                    preferred: 0
                )
            }
        }
    }

    deinit {
        // Ensure the CADisplayLink is invalidated to break the retain cycle.
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                stop()
            }
        } else {
            DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    stop()
                }
            }
        }
    }
}
