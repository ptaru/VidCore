#!/usr/bin/env swift
import AVFoundation
import CoreMedia
import Foundation

// 1. Define the async inspector function
func inspectDolbyConfig(at url: URL) async {
    let asset = AVAsset(url: url)
    
    do {
        // Check if file exists/is reachable
        let exists = FileManager.default.fileExists(atPath: url.path)
        if !exists {
            print("Error: File not found at \(url.path)")
            return
        }

        // Load tracks
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            print("No video track found.")
            return
        }
        
        // Load format descriptions
        let formatDescriptions = try await track.load(.formatDescriptions)
        guard let desc = formatDescriptions.first else {
            print("No format description found.")
            return
        }

        let subType = CMFormatDescriptionGetMediaSubType(desc)

        // Helper to convert UInt32 to String (e.g. 'hvc1')
        func fourCCToString(_ code: FourCharCode) -> String {
            let bytes: [UInt8] = [
                UInt8((code >> 24) & 0xFF),
                UInt8((code >> 16) & 0xFF),
                UInt8((code >> 8) & 0xFF),
                UInt8(code & 0xFF)
            ]
            return String(decoding: bytes, as: UTF8.self)
        }

        let codecTag = fourCCToString(subType)
        print("Codec Tag:   \(codecTag)")
        
        // Print all extensions
        if let extensions = CMFormatDescriptionGetExtensions(desc) as? [String: Any] {
            print("\n=== All Extensions ===")
            for (key, value) in extensions {
                print("\(key): \(value)")
            }
        }
        
        // Helper to print specific extension if present
        func printExtension(_ key: CFString, label: String) {
            if let value = CMFormatDescriptionGetExtension(desc, extensionKey: key) {
                print("\(label): \(value)")
            } else {
                print("\(label): (Not Present)")
            }
        }
        
        print("\n=== Color Properties ===")
        printExtension(kCVImageBufferColorPrimariesKey, label: "Primaries")
        printExtension(kCVImageBufferTransferFunctionKey, label: "Transfer")
        printExtension(kCVImageBufferYCbCrMatrixKey, label: "Matrix")
        printExtension(kCMFormatDescriptionExtension_FullRangeVideo, label: "Full Range")
        
        // Extract atoms
        guard let atoms = CMFormatDescriptionGetExtension(
            desc,
            extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
        ) as? [String: Any] else {
            print("No extension atoms (dvcC/dvvC) found.")
            return
        }
        
        print("\n=== Atoms ===")
        print("Keys: \(atoms.keys.joined(separator: ", "))")
        
        // Find dvcC or dvvC
        var configData: Data?
        var boxType = ""
        
        if let data = atoms["dvcC"] as? Data {
            configData = data
            boxType = "dvcC (Profiles < 8)"
        } else if let data = atoms["dvvC"] as? Data {
            configData = data
            boxType = "dvvC (Profiles 8+)"
        }
        
        guard let data = configData else {
            print("No Dolby Vision configuration found in atoms.")
            return
        }
        
        print("\n=== Found \(boxType) ===")
        print("Raw Hex: \(data.map { String(format: "%02hhx", $0) }.joined())")
        
        // Decode
        if data.count >= 4 {
            let dvMajor = data[0]
            let dvMinor = data[1]
            let profile = (data[2] >> 1) & 0x7F
            let level = ((data[2] & 0x01) << 5) | ((data[3] >> 3) & 0x1F)
            
            let rpuPresent = (data[3] >> 2) & 0x01
            let elPresent  = (data[3] >> 1) & 0x01
            let blPresent  = (data[3] >> 0) & 0x01
            
            print("\n--- Decoded Values ---")
            print("DV Version:  \(dvMajor).\(dvMinor)")
            print("Profile:     \(profile)")
            print("Level:       \(level)")
            print("RPU Flag:    \(rpuPresent) \(rpuPresent == 1 ? "(Present)" : "")")
            print("EL Flag:     \(elPresent) \(elPresent == 1 ? "(Present)" : "")")
            print("BL Flag:     \(blPresent) \(blPresent == 1 ? "(Present)" : "")")
        }
        
    } catch {
        print("Error: \(error.localizedDescription)")
    }
}

// 2. Main Entry Point
let args = CommandLine.arguments

guard args.count > 1 else {
    print("Usage: swift dovi_check.swift \"/path/to/movie.mp4\"")
    exit(1)
}

let filePath = args[1]
let fileURL = URL(fileURLWithPath: filePath)

print("Inspecting: \(fileURL.lastPathComponent)...")

// Run the async function
await inspectDolbyConfig(at: fileURL)