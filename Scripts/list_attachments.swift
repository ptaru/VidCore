#!/usr/bin/env swift
import Foundation
import AVFoundation
import CoreMedia
import CoreVideo

func listAttachments(for url: URL) {
    let asset = AVURLAsset(url: url)
    
    // We use a semaphore to wait for the async work to complete in a CLI context.
    // Using modern load(_:) API to avoid deprecation warnings.
    let semaphore = DispatchSemaphore(value: 0)
    
    var videoTrack: AVAssetTrack?
    var loadError: Error?

    Task {
        do {
            let tracks = try await asset.load(.tracks)
            videoTrack = tracks.first(where: { $0.mediaType == .video })
        } catch {
            loadError = error
        }
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .distantFuture)

    if let error = loadError {
        print("Error loading tracks: \(error)")
        return
    }

    guard let track = videoTrack else {
        print("No video tracks found.")
        return
    }

    do {
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(output)
        
        if !reader.startReading() {
            print("Failed to start reading: \(String(describing: reader.error))")
            return
        }

        guard let sampleBuffer = output.copyNextSampleBuffer() else {
            print("Could not copy next sample buffer.")
            if let error = reader.error {
                print("Reader error: \(error)")
            }
            return
        }

        print("--- CMSampleBuffer Buffer-level Attachments (Propagated) ---")
        if let dict = CMCopyDictionaryOfAttachments(allocator: kCFAllocatorDefault, target: sampleBuffer, attachmentMode: kCMAttachmentMode_ShouldPropagate) as? [String: Any] {
            for (key, value) in dict {
                print("  \(key): \(value)")
            }
        } else {
            print("  None")
        }

        print("\n--- CMSampleBuffer Buffer-level Attachments (Non-Propagated) ---")
        if let dict = CMCopyDictionaryOfAttachments(allocator: kCFAllocatorDefault, target: sampleBuffer, attachmentMode: kCMAttachmentMode_ShouldNotPropagate) as? [String: Any] {
            for (key, value) in dict {
                print("  \(key): \(value)")
            }
        } else {
            print("  None")
        }

        print("\n--- CMSampleBuffer Sample-level Attachments Array ---")
        if let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [NSDictionary] {
            for (index, dict) in attachmentsArray.enumerated() {
                print("Sample \(index):")
                for (key, value) in dict {
                    print("  \(key): \(value)")
                }
            }
        } else {
            print("  None")
        }

        if let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) {
            print("\n--- CMFormatDescription Extensions ---")
            if let extensions = CMFormatDescriptionGetExtensions(formatDescription) as? [String: Any] {
                for (key, value) in extensions {
                    print("  \(key): \(value)")
                }
            }
        }

        if let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            print("\n--- CVPixelBuffer Attachments (Propagated) ---")
            if let attachments = CVBufferCopyAttachments(imageBuffer, .shouldPropagate) as? [String: Any] {
                for (key, value) in attachments {
                    print("  \(key): \(value)")
                }
            }
            
            print("\n--- CVPixelBuffer Attachments (Non-Propagated) ---")
            if let nonPropagated = CVBufferCopyAttachments(imageBuffer, .shouldNotPropagate) as? [String: Any] {
                for (key, value) in nonPropagated {
                    print("  \(key) (non-propagated): \(value)")
                }
            }
        }
    } catch {
        print("Error: \(error)")
    }
}

let arguments = CommandLine.arguments
if arguments.count < 2 {
    print("Usage: ./list_attachments.swift <video-file-path>")
    exit(1)
}

let filePath = arguments[1]
let url = URL(fileURLWithPath: filePath)
listAttachments(for: url)