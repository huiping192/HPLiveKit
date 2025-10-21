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
    // Mark as nonisolated(unsafe) to allow access from deinit
    nonisolated(unsafe) private var converter: AudioConverterRef?

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
            // CMBlockBuffer is automatically memory managed in Swift 6
            _ = blockBuffer
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

        // Setup buffer properties before using in closure to avoid data race
        outBufferList.mBuffers.mNumberChannels = targetChannels
        outBufferList.mBuffers.mDataByteSize = UInt32(outputSize)
        outputData.withUnsafeMutableBytes { bytes in
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
