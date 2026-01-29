#!/usr/bin/env swift
import AVFoundation
import CoreVideo
import Foundation

func checkAmbientViewingEnvironment(url: URL) {
    let asset = AVAsset(url: url)
    
    // Use a semaphore or wait to ensure asset properties are loaded if needed, 
    // but AVAssetReader usually handles it if we don't need metadata immediately.
    
    let reader: AVAssetReader
    do {
        reader = try AVAssetReader(asset: asset)
    } catch {
        print("Error creating reader: \(error)")
        return
    }

    guard let videoTrack = asset.tracks(withMediaType: .video).first else {
        print("No video track found")
        return
    }

    // Requesting 10-bit or 8-bit. Since many HDR files are 10-bit, let's try to get a format that preserves metadata.
    // However, for just checking attachments, even 8-bit might work if the reader propagates them.
    let outputSettings: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    ]
    let trackOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)
    reader.add(trackOutput)

    guard reader.startReading() else {
        print("Failed to start reading: \(reader.error?.localizedDescription ?? "Unknown error")")
        return
    }

    print("Checking for kCVImageBufferAmbientViewingEnvironmentKey...")
    
    var frameCount = 0
    var found = false
    while let sampleBuffer = trackOutput.copyNextSampleBuffer() {
        frameCount += 1
        if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            if let attachment = CVBufferGetAttachment(pixelBuffer, kCVImageBufferAmbientViewingEnvironmentKey, nil) {
                found = true
                print("Found attachment on frame \(frameCount):")
                let val = attachment.takeUnretainedValue()
                print("Type: \(type(of: val))")
                print("Value: \(val)")
                
                // If it's CFData, we might want to see the bytes.
                if let data = val as? Data, data.count == 8 {
                    print("Data hex: \(data.map { String(format: "%02x", $0) }.joined())")
                    
                    // HEVC Ambient Viewing Environment box:
                    // 4 bytes: ambient_illuminance (32-bit unsigned, 0.0001 lux units)
                    // 2 bytes: ambient_light_x (16-bit unsigned, 0.00002 units)
                    // 2 bytes: ambient_light_y (16-bit unsigned, 0.00002 units)
                    
                    let illuminanceRaw = data.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
                    let xRaw = data.dropFirst(4).prefix(2).withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
                    let yRaw = data.dropFirst(6).prefix(2).withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
                    
                    let illuminance = Double(illuminanceRaw) * 0.0001
                    let x = Double(xRaw) * 0.00002
                    let y = Double(yRaw) * 0.00002
                    
                    print(String(format: "  Illuminance: %.4f lux", illuminance))
                    print(String(format: "  Chromaticity: (x: %.4f, y: %.4f)", x, y))
                }
            }
        }
        
        // Check first 10 frames for now
        if frameCount >= 10 {
            break
        }
    }
    
    if !found {
        print("kCVImageBufferAmbientViewingEnvironmentKey not found in the first \(frameCount) frames.")
    }
    
    reader.cancelReading()
}

let args = ProcessInfo.processInfo.arguments
if args.count < 2 {
    print("Usage: swift check_ambient.swift <path_to_video>")
} else {
    let filePath = args[1]
    let url = URL(fileURLWithPath: filePath)
    checkAmbientViewingEnvironment(url: url)
}
