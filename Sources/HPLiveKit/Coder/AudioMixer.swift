//
//  AudioMixer.swift
//  HPLiveKit
//
//  Created for audio mixing functionality
//

import Foundation
@preconcurrency import CoreMedia
@preconcurrency import AVFoundation
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
    /// Input continuation must be nonisolated(unsafe) because CMSampleBuffer is not Sendable
    nonisolated(unsafe) private let appAudioContinuation: AsyncStream<CMSampleBuffer>.Continuation

    private let micAudioStream: AsyncStream<CMSampleBuffer>
    /// Input continuation must be nonisolated(unsafe) because CMSampleBuffer is not Sendable
    nonisolated(unsafe) private let micAudioContinuation: AsyncStream<CMSampleBuffer>.Continuation

    // MARK: - Output Stream

    nonisolated(unsafe) private let _outputStream: AsyncStream<CMSampleBuffer>
    /// Output continuation must be nonisolated(unsafe) because CMSampleBuffer is not Sendable
    nonisolated(unsafe) private let outputContinuation: AsyncStream<CMSampleBuffer>.Continuation

    nonisolated var outputStream: AsyncStream<CMSampleBuffer> {
        _outputStream
    }

    // MARK: - Processing State

    private var appAudioBuffer: [TimestampedBuffer] = []
    private var micAudioBuffer: [TimestampedBuffer] = []

    private let bufferTimeThreshold: CMTime = CMTime(seconds: 0.1, preferredTimescale: 1000000) // 100ms

    // Processing tasks - use nonisolated(unsafe) to store tasks
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
        self.appProcessingTask = Task { [weak self] in
            guard let self = self else { return }
            await self.processAppAudioStream()
        }

        self.micProcessingTask = Task { [weak self] in
            guard let self = self else { return }
            await self.processMicAudioStream()
        }

        self.mixingTask = Task { [weak self] in
            guard let self = self else { return }
            await self.mixAudioStreams()
        }
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
        // Strategy: Single-stream passthrough when only one stream has data
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
            // CMBlockBuffer is automatically memory managed in Swift 6
            _ = blockBuffer
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
            refcon: nil,
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
