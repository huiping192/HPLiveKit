# Audio Mixer Implementation Guide

## Overview

This document provides the complete implementation guide for adding microphone audio mixing functionality to HPLiveKit's screen share mode.

## Architecture

```
┌──────────────┐       ┌─────────────┐       ┌──────────────┐
│ pushAppAudio │──────▶│             │       │              │
└──────────────┘       │ AudioMixer  │──────▶│   Encoder    │
┌──────────────┐       │   (Actor)   │       │              │
│ pushMicAudio │──────▶│             │       └──────────────┘
└──────────────┘       └─────────────┘
                          ↓
                    AudioResampler
```

## Implementation Steps

---

## Step 1: Create AudioResampler Actor

**File**: `Sources/HPLiveKit/Coder/AudioResampler.swift`

### Purpose
- Normalize audio format to target specifications
- Resample to 48000 Hz sample rate
- Convert mono to stereo
- Normalize bit depth to 16-bit PCM

### Implementation

```swift
//
//  AudioResampler.swift
//  HPLiveKit
//
//  Created for audio format normalization
//

import Foundation
import CoreMedia
import AudioToolbox
import AVFoundation
import os

/// Audio format resampler using Swift 6 Actor for thread safety
/// Converts input CMSampleBuffer to normalized format
actor AudioResampler {
    private static let logger = Logger(subsystem: "com.hplivekit", category: "AudioResampler")

    // Target format specifications
    private let targetSampleRate: Double
    private let targetChannels: UInt32
    private let targetBitsPerChannel: UInt32

    // Audio converter for resampling
    private var converter: AudioConverterRef?

    // Source format tracking
    private var sourceSampleRate: Double = 0
    private var sourceChannels: UInt32 = 0
    private var sourceBitsPerChannel: UInt32 = 0

    init(targetSampleRate: Double = 48000, targetChannels: UInt32 = 2, targetBitsPerChannel: UInt32 = 16) {
        self.targetSampleRate = targetSampleRate
        self.targetChannels = targetChannels
        self.targetBitsPerChannel = targetBitsPerChannel
    }

    deinit {
        if let converter = converter {
            AudioConverterDispose(converter)
        }
    }

    /// Resample audio sample buffer to target format
    /// - Parameter sampleBuffer: Input sample buffer
    /// - Returns: Resampled sample buffer with target format, or nil if conversion fails
    func resample(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            Self.logger.error("Cannot get format description")
            return nil
        }

        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee else {
            Self.logger.error("Cannot get audio stream basic description")
            return nil
        }

        // Check if resampling is needed
        let needsResampling = asbd.mSampleRate != targetSampleRate ||
                             asbd.mChannelsPerFrame != targetChannels ||
                             asbd.mBitsPerChannel != targetBitsPerChannel

        if !needsResampling {
            return sampleBuffer // Return original if format matches
        }

        // Setup converter if format changed
        if !setupConverterIfNeeded(sourceFormat: asbd) {
            Self.logger.error("Failed to setup audio converter")
            return nil
        }

        // Extract audio data
        guard let audioData = extractAudioData(from: sampleBuffer) else {
            Self.logger.error("Failed to extract audio data")
            return nil
        }

        // Convert audio data
        guard let convertedData = convert(audioData: audioData, sourceFormat: asbd) else {
            Self.logger.error("Failed to convert audio data")
            return nil
        }

        // Create new sample buffer with converted data
        return createSampleBuffer(from: convertedData,
                                 timestamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    // MARK: - Private Methods

    private func setupConverterIfNeeded(sourceFormat: AudioStreamBasicDescription) -> Bool {
        // Check if format changed
        if sourceSampleRate == sourceFormat.mSampleRate &&
           sourceChannels == sourceFormat.mChannelsPerFrame &&
           sourceBitsPerChannel == sourceFormat.mBitsPerChannel,
           converter != nil {
            return true // Converter already setup
        }

        // Dispose old converter
        if let oldConverter = converter {
            AudioConverterDispose(oldConverter)
            converter = nil
        }

        // Save source format
        sourceSampleRate = sourceFormat.mSampleRate
        sourceChannels = sourceFormat.mChannelsPerFrame
        sourceBitsPerChannel = sourceFormat.mBitsPerChannel

        // Create input format
        var inputFormat = sourceFormat

        // Create output format
        var outputFormat = AudioStreamBasicDescription()
        outputFormat.mSampleRate = targetSampleRate
        outputFormat.mFormatID = kAudioFormatLinearPCM
        outputFormat.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
        outputFormat.mChannelsPerFrame = targetChannels
        outputFormat.mBitsPerChannel = targetBitsPerChannel
        outputFormat.mBytesPerFrame = targetBitsPerChannel / 8 * targetChannels
        outputFormat.mFramesPerPacket = 1
        outputFormat.mBytesPerPacket = outputFormat.mBytesPerFrame

        // Create converter
        let status = AudioConverterNew(&inputFormat, &outputFormat, &converter)
        if status != noErr {
            Self.logger.error("AudioConverterNew failed: \(status)")
            return false
        }

        Self.logger.info("Audio converter created - Input: \(sourceFormat.mSampleRate)Hz \(sourceFormat.mChannelsPerFrame)ch \(sourceFormat.mBitsPerChannel)bit -> Output: \(self.targetSampleRate)Hz \(self.targetChannels)ch \(self.targetBitsPerChannel)bit")

        return true
    }

    private func extractAudioData(from sampleBuffer: CMSampleBuffer) -> Data? {
        var blockBuffer: CMBlockBuffer?
        var audioBufferList = AudioBufferList()

        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        guard status == noErr else {
            Self.logger.error("Failed to get audio buffer list: \(status)")
            return nil
        }

        defer {
            if let blockBuffer = blockBuffer {
                CFRelease(blockBuffer)
            }
        }

        let buffers = UnsafeMutableAudioBufferListPointer(&audioBufferList)
        guard let buffer = buffers.first, let data = buffer.mData else {
            return nil
        }

        return Data(bytes: data, count: Int(buffer.mDataByteSize))
    }

    private func convert(audioData: Data, sourceFormat: AudioStreamBasicDescription) -> Data? {
        guard let converter = converter else { return nil }

        // Calculate output buffer size
        let sourceFrames = audioData.count / Int(sourceFormat.mBytesPerFrame)
        let targetFrames = Int(Double(sourceFrames) * targetSampleRate / sourceFormat.mSampleRate)
        let outputSize = targetFrames * Int(targetBitsPerChannel / 8 * targetChannels)

        var outputData = Data(count: outputSize)

        // Setup input buffer list
        var inBuffer = AudioBuffer()
        inBuffer.mNumberChannels = sourceFormat.mChannelsPerFrame
        inBuffer.mDataByteSize = UInt32(audioData.count)
        audioData.withUnsafeBytes { bytes in
            inBuffer.mData = UnsafeMutableRawPointer(mutating: bytes.baseAddress!)
        }

        var inBufferList = AudioBufferList()
        inBufferList.mNumberBuffers = 1
        inBufferList.mBuffers = inBuffer

        // Setup output buffer list
        var outBufferList = AudioBufferList()
        outBufferList.mNumberBuffers = 1
        outputData.withUnsafeMutableBytes { bytes in
            outBufferList.mBuffers.mNumberChannels = targetChannels
            outBufferList.mBuffers.mDataByteSize = UInt32(outputSize)
            outBufferList.mBuffers.mData = bytes.baseAddress
        }

        var ioOutputDataPacketSize = UInt32(targetFrames)

        let status = AudioConverterFillComplexBuffer(
            converter,
            { (converter, ioNumDataPackets, ioData, _, inUserData) -> OSStatus in
                guard let userData = inUserData else { return noErr }
                let bufferList = userData.assumingMemoryBound(to: AudioBufferList.self).pointee
                ioData.pointee = bufferList
                return noErr
            },
            &inBufferList,
            &ioOutputDataPacketSize,
            &outBufferList,
            nil
        )

        if status != noErr {
            Self.logger.error("AudioConverterFillComplexBuffer failed: \(status)")
            return nil
        }

        return Data(bytes: outBufferList.mBuffers.mData!,
                   count: Int(outBufferList.mBuffers.mDataByteSize))
    }

    private func createSampleBuffer(from data: Data, timestamp: CMTime) -> CMSampleBuffer? {
        // Create audio format description
        var outputFormat = AudioStreamBasicDescription()
        outputFormat.mSampleRate = targetSampleRate
        outputFormat.mFormatID = kAudioFormatLinearPCM
        outputFormat.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
        outputFormat.mChannelsPerFrame = targetChannels
        outputFormat.mBitsPerChannel = targetBitsPerChannel
        outputFormat.mBytesPerFrame = targetBitsPerChannel / 8 * targetChannels
        outputFormat.mFramesPerPacket = 1
        outputFormat.mBytesPerPacket = outputFormat.mBytesPerFrame

        var formatDescription: CMAudioFormatDescription?
        var status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &outputFormat,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )

        guard status == noErr, let formatDesc = formatDescription else {
            Self.logger.error("Failed to create format description: \(status)")
            return nil
        }

        // Create block buffer
        var blockBuffer: CMBlockBuffer?
        status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        guard status == noErr, let blockBuf = blockBuffer else {
            Self.logger.error("Failed to create block buffer: \(status)")
            return nil
        }

        // Copy data
        status = data.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!,
                blockBuffer: blockBuf,
                offsetIntoDestination: 0,
                dataLength: data.count
            )
        }

        guard status == noErr else {
            Self.logger.error("Failed to copy data to block buffer: \(status)")
            return nil
        }

        // Create sample buffer
        let frameCount = data.count / Int(outputFormat.mBytesPerFrame)
        var sampleBuffer: CMSampleBuffer?
        status = CMAudioSampleBufferCreateWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuf,
            dataReady: true,
            makeDataReadyCallback: nil,
            makeDataReadyRefcon: nil,
            formatDescription: formatDesc,
            sampleCount: frameCount,
            presentationTimeStamp: timestamp,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        )

        guard status == noErr, let sample = sampleBuffer else {
            Self.logger.error("Failed to create sample buffer: \(status)")
            return nil
        }

        return sample
    }
}
```

---

## Step 2: Create AudioMixer Actor

**File**: `Sources/HPLiveKit/Coder/AudioMixer.swift`

### Purpose
- Mix App audio and Mic audio streams
- Handle single-stream passthrough
- Apply volume ratio (App 70%, Mic 100%)
- Output mixed audio stream

### Implementation

```swift
//
//  AudioMixer.swift
//  HPLiveKit
//
//  Created for audio mixing functionality
//

import Foundation
import CoreMedia
import AVFoundation
import os

/// Audio mixer using Swift 6 Actor for thread safety
/// Mixes app audio and microphone audio with configurable volume ratios
actor AudioMixer {
    private static let logger = Logger(subsystem: "com.hplivekit", category: "AudioMixer")

    // MARK: - Configuration

    private let targetSampleRate: Double
    private let appVolume: Float  // Default 0.7 (70%)
    private let micVolume: Float  // Default 1.0 (100%)

    // MARK: - Audio Resampler

    private let resampler: AudioResampler

    // MARK: - Input Streams

    private let appAudioStream: AsyncStream<CMSampleBuffer>
    private let appAudioContinuation: AsyncStream<CMSampleBuffer>.Continuation

    private let micAudioStream: AsyncStream<CMSampleBuffer>
    private let micAudioContinuation: AsyncStream<CMSampleBuffer>.Continuation

    // MARK: - Output Stream

    private let _outputStream: AsyncStream<CMSampleBuffer>
    private let outputContinuation: AsyncStream<CMSampleBuffer>.Continuation

    nonisolated var outputStream: AsyncStream<CMSampleBuffer> {
        _outputStream
    }

    // MARK: - Processing State

    private var appAudioBuffer: [TimestampedBuffer] = []
    private var micAudioBuffer: [TimestampedBuffer] = []

    private let bufferTimeThreshold: CMTime = CMTime(seconds: 0.1, preferredTimescale: 1000000) // 100ms

    // Processing tasks
    nonisolated(unsafe) private var appProcessingTask: Task<Void, Never>?
    nonisolated(unsafe) private var micProcessingTask: Task<Void, Never>?
    nonisolated(unsafe) private var mixingTask: Task<Void, Never>?

    // MARK: - Helper Types

    private struct TimestampedBuffer {
        let sampleBuffer: CMSampleBuffer
        let timestamp: CMTime
    }

    // MARK: - Initialization

    init(targetSampleRate: Double = 48000, appVolume: Float = 0.7, micVolume: Float = 1.0) {
        self.targetSampleRate = targetSampleRate
        self.appVolume = appVolume
        self.micVolume = micVolume

        // Create resampler
        self.resampler = AudioResampler(targetSampleRate: targetSampleRate)

        // Create input streams
        var appCont: AsyncStream<CMSampleBuffer>.Continuation!
        self.appAudioStream = AsyncStream { continuation in
            appCont = continuation
        }
        self.appAudioContinuation = appCont

        var micCont: AsyncStream<CMSampleBuffer>.Continuation!
        self.micAudioStream = AsyncStream { continuation in
            micCont = continuation
        }
        self.micAudioContinuation = micCont

        // Create output stream
        var outputCont: AsyncStream<CMSampleBuffer>.Continuation!
        self._outputStream = AsyncStream { continuation in
            outputCont = continuation
        }
        self.outputContinuation = outputCont

        // Start processing tasks
        let appTask = Task { [weak self] in
            await self?.processAppAudioStream()
        }
        self.appProcessingTask = appTask

        let micTask = Task { [weak self] in
            await self?.processMicAudioStream()
        }
        self.micProcessingTask = micTask

        let mixTask = Task { [weak self] in
            await self?.mixAudioStreams()
        }
        self.mixingTask = mixTask
    }

    deinit {
        appProcessingTask?.cancel()
        micProcessingTask?.cancel()
        mixingTask?.cancel()

        appAudioContinuation.finish()
        micAudioContinuation.finish()
        outputContinuation.finish()
    }

    // MARK: - Public API

    /// Push app audio sample buffer
    nonisolated func pushAppAudio(_ sampleBuffer: CMSampleBuffer) {
        appAudioContinuation.yield(sampleBuffer)
    }

    /// Push microphone audio sample buffer
    nonisolated func pushMicAudio(_ sampleBuffer: CMSampleBuffer) {
        micAudioContinuation.yield(sampleBuffer)
    }

    /// Stop the mixer and finish all streams
    func stop() {
        appProcessingTask?.cancel()
        micProcessingTask?.cancel()
        mixingTask?.cancel()

        appAudioContinuation.finish()
        micAudioContinuation.finish()
        outputContinuation.finish()

        appAudioBuffer.removeAll()
        micAudioBuffer.removeAll()
    }

    // MARK: - Private Processing Methods

    private func processAppAudioStream() async {
        for await sampleBuffer in appAudioStream {
            // Resample to target format
            guard let normalized = await resampler.resample(sampleBuffer) else {
                Self.logger.warning("Failed to resample app audio")
                continue
            }

            let timestamp = CMSampleBufferGetPresentationTimeStamp(normalized)
            appAudioBuffer.append(TimestampedBuffer(sampleBuffer: normalized, timestamp: timestamp))

            Self.logger.debug("App audio buffered: \(timestamp.seconds)s, buffer size: \(self.appAudioBuffer.count)")
        }
    }

    private func processMicAudioStream() async {
        for await sampleBuffer in micAudioStream {
            // Resample to target format
            guard let normalized = await resampler.resample(sampleBuffer) else {
                Self.logger.warning("Failed to resample mic audio")
                continue
            }

            let timestamp = CMSampleBufferGetPresentationTimeStamp(normalized)
            micAudioBuffer.append(TimestampedBuffer(sampleBuffer: normalized, timestamp: timestamp))

            Self.logger.debug("Mic audio buffered: \(timestamp.seconds)s, buffer size: \(self.micAudioBuffer.count)")
        }
    }

    private func mixAudioStreams() async {
        // Periodically check buffers and mix
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms

            await processMixing()
        }
    }

    private func processMixing() async {
        // Strategy: Single-stream passthrough (直接编码单路音频)
        // If only one stream has data, output it directly

        if !appAudioBuffer.isEmpty && micAudioBuffer.isEmpty {
            // Only app audio available
            let buffer = appAudioBuffer.removeFirst()
            outputContinuation.yield(buffer.sampleBuffer)
            Self.logger.debug("Output app audio only: \(buffer.timestamp.seconds)s")
            return
        }

        if appAudioBuffer.isEmpty && !micAudioBuffer.isEmpty {
            // Only mic audio available
            let buffer = micAudioBuffer.removeFirst()
            outputContinuation.yield(buffer.sampleBuffer)
            Self.logger.debug("Output mic audio only: \(buffer.timestamp.seconds)s")
            return
        }

        if appAudioBuffer.isEmpty || micAudioBuffer.isEmpty {
            // No data to process
            return
        }

        // Both streams have data, mix them
        let appBuffer = appAudioBuffer.first!
        let micBuffer = micAudioBuffer.first!

        // Check timestamp alignment (within 100ms)
        let timeDiff = CMTimeSubtract(appBuffer.timestamp, micBuffer.timestamp)
        if abs(timeDiff.seconds) > bufferTimeThreshold.seconds {
            Self.logger.warning("Timestamp mismatch: app=\(appBuffer.timestamp.seconds)s, mic=\(micBuffer.timestamp.seconds)s, diff=\(timeDiff.seconds)s")

            // Remove older buffer and retry
            if CMTimeCompare(appBuffer.timestamp, micBuffer.timestamp) < 0 {
                appAudioBuffer.removeFirst()
            } else {
                micAudioBuffer.removeFirst()
            }
            return
        }

        // Mix audio
        if let mixed = mixBuffers(appBuffer: appBuffer.sampleBuffer, micBuffer: micBuffer.sampleBuffer) {
            outputContinuation.yield(mixed)
            Self.logger.debug("Output mixed audio: app=\(appBuffer.timestamp.seconds)s, mic=\(micBuffer.timestamp.seconds)s")
        } else {
            Self.logger.warning("Failed to mix audio buffers")
        }

        // Remove processed buffers
        appAudioBuffer.removeFirst()
        micAudioBuffer.removeFirst()
    }

    private func mixBuffers(appBuffer: CMSampleBuffer, micBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        // Extract PCM data from both buffers
        guard let appData = extractPCMData(from: appBuffer),
              let micData = extractPCMData(from: micBuffer) else {
            return nil
        }

        // Mix PCM data with volume ratio
        guard let mixedData = mixPCMData(app: appData, mic: micData) else {
            return nil
        }

        // Create new sample buffer with mixed data
        let timestamp = CMSampleBufferGetPresentationTimeStamp(appBuffer)
        return createSampleBuffer(from: mixedData, timestamp: timestamp)
    }

    private func extractPCMData(from sampleBuffer: CMSampleBuffer) -> Data? {
        var blockBuffer: CMBlockBuffer?
        var audioBufferList = AudioBufferList()

        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        guard status == noErr else {
            Self.logger.error("Failed to get audio buffer list: \(status)")
            return nil
        }

        defer {
            if let blockBuffer = blockBuffer {
                CFRelease(blockBuffer)
            }
        }

        let buffers = UnsafeMutableAudioBufferListPointer(&audioBufferList)
        guard let buffer = buffers.first, let data = buffer.mData else {
            return nil
        }

        return Data(bytes: data, count: Int(buffer.mDataByteSize))
    }

    private func mixPCMData(app: Data, mic: Data) -> Data? {
        // Assume both are 16-bit signed integer PCM
        let sampleCount = min(app.count, mic.count) / 2 // 16-bit = 2 bytes per sample
        var mixedData = Data(count: sampleCount * 2)

        app.withUnsafeBytes { appBytes in
            mic.withUnsafeBytes { micBytes in
                mixedData.withUnsafeMutableBytes { mixedBytes in
                    let appSamples = appBytes.bindMemory(to: Int16.self)
                    let micSamples = micBytes.bindMemory(to: Int16.self)
                    let mixedSamples = mixedBytes.bindMemory(to: Int16.self)

                    for i in 0..<sampleCount {
                        // Apply volume ratio: App 70%, Mic 100%
                        let appValue = Float(appSamples[i]) * appVolume
                        let micValue = Float(micSamples[i]) * micVolume

                        // Mix and clamp to prevent overflow
                        var mixed = appValue + micValue
                        mixed = max(-32768, min(32767, mixed))

                        mixedSamples[i] = Int16(mixed)
                    }
                }
            }
        }

        return mixedData
    }

    private func createSampleBuffer(from data: Data, timestamp: CMTime) -> CMSampleBuffer? {
        // Create audio format description (16-bit stereo PCM at target sample rate)
        var outputFormat = AudioStreamBasicDescription()
        outputFormat.mSampleRate = targetSampleRate
        outputFormat.mFormatID = kAudioFormatLinearPCM
        outputFormat.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
        outputFormat.mChannelsPerFrame = 2 // Stereo
        outputFormat.mBitsPerChannel = 16
        outputFormat.mBytesPerFrame = 4 // 2 bytes * 2 channels
        outputFormat.mFramesPerPacket = 1
        outputFormat.mBytesPerPacket = 4

        var formatDescription: CMAudioFormatDescription?
        var status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &outputFormat,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )

        guard status == noErr, let formatDesc = formatDescription else {
            Self.logger.error("Failed to create format description: \(status)")
            return nil
        }

        // Create block buffer
        var blockBuffer: CMBlockBuffer?
        status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        guard status == noErr, let blockBuf = blockBuffer else {
            Self.logger.error("Failed to create block buffer: \(status)")
            return nil
        }

        // Copy data
        status = data.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!,
                blockBuffer: blockBuf,
                offsetIntoDestination: 0,
                dataLength: data.count
            )
        }

        guard status == noErr else {
            Self.logger.error("Failed to copy data to block buffer: \(status)")
            return nil
        }

        // Create sample buffer
        let frameCount = data.count / 4 // 4 bytes per frame (16-bit stereo)
        var sampleBuffer: CMSampleBuffer?
        status = CMAudioSampleBufferCreateWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuf,
            dataReady: true,
            makeDataReadyCallback: nil,
            makeDataReadyRefcon: nil,
            formatDescription: formatDesc,
            sampleCount: frameCount,
            presentationTimeStamp: timestamp,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        )

        guard status == noErr, let sample = sampleBuffer else {
            Self.logger.error("Failed to create sample buffer: \(status)")
            return nil
        }

        return sample
    }
}
```

---

## Step 3: Update LiveSession Integration

**File**: `Sources/HPLiveKit/LiveSession.swift`

### Changes Required

#### 3.1 Add AudioMixer Property

```swift
// Add after line 96 (after publisher property)
// Audio mixer (only for screenShare mode)
private var audioMixer: AudioMixer?

// Add after line 93 (after encoder tasks)
private var mixerTask: Task<Void, Never>?
```

#### 3.2 Update Initialization (in `init` method around line 142)

```swift
// Add after line 173 (after startEncoderStreams())

// Setup audio mixer for screenShare mode
if mode == .screenShare {
    audioMixer = AudioMixer(
        targetSampleRate: Double(audioConfiguration.audioSampleRate.rawValue),
        appVolume: 0.7,
        micVolume: 1.0
    )
    startMixerStream()
}
```

#### 3.3 Update Deinit (around line 224)

```swift
// Add after line 231 (after audioEncoderTask?.cancel())
mixerTask?.cancel()
```

#### 3.4 Update pushAppAudio Method (replace lines 296-310)

```swift
/// Push app audio sample buffer (for RPBroadcastSampleHandler)
/// - Parameter sampleBuffer: App audio sample buffer from RPBroadcastSampleHandler
public func pushAppAudio(_ sampleBuffer: CMSampleBuffer) {
    guard mode == .screenShare else {
        #if DEBUG
        print("[HPLiveKit] pushAppAudio is only available in screenShare mode")
        #endif
        return
    }
    guard uploading else { return }

    timestampSynchronizer.recordIfNeeded(sampleBuffer)

    // Push to audio mixer if available, otherwise encode directly
    if let audioMixer = audioMixer {
        audioMixer.pushAppAudio(sampleBuffer)
    } else {
        audioEncoder.encode(sampleBuffer: sampleBuffer)
    }
}
```

#### 3.5 Implement pushMicAudio Method (replace lines 312-327)

```swift
/// Push mic audio sample buffer (for RPBroadcastSampleHandler)
/// - Parameter sampleBuffer: Mic audio sample buffer from RPBroadcastSampleHandler
public func pushMicAudio(_ sampleBuffer: CMSampleBuffer) {
    guard mode == .screenShare else {
        #if DEBUG
        print("[HPLiveKit] pushMicAudio is only available in screenShare mode")
        #endif
        return
    }
    guard uploading else { return }

    timestampSynchronizer.recordIfNeeded(sampleBuffer)

    // Push to audio mixer
    audioMixer?.pushMicAudio(sampleBuffer)
}
```

#### 3.6 Add startMixerStream Method (add in private extension around line 394)

```swift
/// Start audio mixer output stream subscription
/// Subscribe to mixer output and encode mixed audio
func startMixerStream() {
    guard let audioMixer = audioMixer else { return }

    mixerTask?.cancel()
    mixerTask = Task { [weak self] in
        guard let self = self else { return }
        for await mixedBuffer in await audioMixer.outputStream {
            guard self.uploading else { continue }

            // Mixed audio already has normalized timestamp from mixer
            // Directly encode without additional timestamp recording
            self.audioEncoder.encode(sampleBuffer: mixedBuffer)
        }
    }
}
```

---

## Step 4: Add Configuration Options

**File**: `Sources/HPLiveKit/Configuration/LiveAudioConfiguration.swift`

### Changes Required

Add audio mixing configuration properties to the `LiveAudioConfiguration` struct.

#### 4.1 Add Properties (around line 20-30, after existing properties)

```swift
// Audio mixing configuration (for screenShare mode)
public var audioMixingEnabled: Bool = true
public var appAudioVolume: Float = 0.7  // 70% for app audio
public var micAudioVolume: Float = 1.0  // 100% for mic audio
```

#### 4.2 Update Initializer

If there's a custom initializer, add these parameters:

```swift
public init(
    // ... existing parameters ...
    audioMixingEnabled: Bool = true,
    appAudioVolume: Float = 0.7,
    micAudioVolume: Float = 1.0
) {
    // ... existing assignments ...
    self.audioMixingEnabled = audioMixingEnabled
    self.appAudioVolume = appAudioVolume
    self.micAudioVolume = micAudioVolume
}
```

#### 4.3 Update Factory Methods

Update factory methods in `LiveAudioConfigurationFactory` to include new parameters:

```swift
// Example for createHigh() method
public static func createHigh() -> LiveAudioConfiguration {
    var config = LiveAudioConfiguration()
    // ... existing settings ...
    config.audioMixingEnabled = true
    config.appAudioVolume = 0.7
    config.micAudioVolume = 1.0
    return config
}
```

#### 4.4 Update LiveSession to Use Configuration

In `LiveSession.swift`, update the AudioMixer initialization (Step 3.2) to use configuration:

```swift
// Setup audio mixer for screenShare mode
if mode == .screenShare && audioConfiguration.audioMixingEnabled {
    audioMixer = AudioMixer(
        targetSampleRate: Double(audioConfiguration.audioSampleRate.rawValue),
        appVolume: audioConfiguration.appAudioVolume,
        micVolume: audioConfiguration.micAudioVolume
    )
    startMixerStream()
}
```

And update the fallback logic in `pushAppAudio`:

```swift
// Push to audio mixer if available and enabled, otherwise encode directly
if let audioMixer = audioMixer, audioConfiguration.audioMixingEnabled {
    audioMixer.pushAppAudio(sampleBuffer)
} else {
    audioEncoder.encode(sampleBuffer: sampleBuffer)
}
```

---

## Implementation Checklist

- [ ] Step 1: Create `AudioResampler.swift`
- [ ] Step 2: Create `AudioMixer.swift`
- [ ] Step 3: Update `LiveSession.swift`
  - [ ] Add audioMixer and mixerTask properties
  - [ ] Update init method
  - [ ] Update deinit method
  - [ ] Update pushAppAudio method
  - [ ] Implement pushMicAudio method
  - [ ] Add startMixerStream method
- [ ] Step 4: Update `LiveAudioConfiguration.swift`
  - [ ] Add mixing properties
  - [ ] Update initializers
  - [ ] Update factory methods
  - [ ] Update LiveSession integration

---

## Testing Strategy

### Unit Tests

1. **AudioResampler Tests**
   - Test sample rate conversion (44.1kHz -> 48kHz)
   - Test channel conversion (mono -> stereo)
   - Test bit depth conversion (8-bit -> 16-bit)
   - Test passthrough when format matches

2. **AudioMixer Tests**
   - Test dual-stream mixing
   - Test single-stream passthrough (app only)
   - Test single-stream passthrough (mic only)
   - Test volume ratio application
   - Test timestamp alignment
   - Test buffer management

3. **Integration Tests**
   - Test end-to-end screen share with app audio only
   - Test end-to-end screen share with mic audio only
   - Test end-to-end screen share with mixed audio
   - Test switching between mixing modes

### Manual Testing

1. **Create test RPBroadcastSampleHandler**
   - Test with game audio (app audio only)
   - Test with voice commentary (mic audio only)
   - Test with both app and mic audio
   - Verify audio quality and sync

2. **Performance Testing**
   - Monitor CPU usage during mixing
   - Check for audio dropouts
   - Measure latency impact

---

## Known Limitations

1. **Audio Format Support**: Currently only supports 16-bit PCM format
2. **Sample Rate**: Fixed at 48kHz output (configurable but not dynamic)
3. **Timestamp Alignment**: Uses 100ms threshold which may need tuning
4. **Buffer Management**: Simple FIFO strategy, may need smarter buffering

---

## Future Enhancements

1. **Dynamic Volume Control**: Allow runtime volume adjustment via API
2. **Advanced Mixing**: Support more than 2 audio sources
3. **Audio Effects**: Add equalizer, noise cancellation, etc.
4. **Format Auto-Detection**: Better handling of various input formats
5. **Adaptive Buffering**: Smarter buffer management based on network conditions

---

## References

- [Apple AVAudioEngine Documentation](https://developer.apple.com/documentation/avfaudio/avaudioengine)
- [Core Audio Programming Guide](https://developer.apple.com/library/archive/documentation/MusicAudio/Conceptual/CoreAudioOverview/)
- [ReplayKit Framework](https://developer.apple.com/documentation/replaykit)
- [Audio Mixing Best Practices](https://developer.apple.com/videos/play/wwdc2021/10089/)
