//
//  LiveAudioAACEncoder.swift
//  HPLiveKit
//
//  Created by Huiping Guo on 2018/08/20.
//  Copyright © 2018 Huiping Guo. All rights reserved.
//

import Foundation
import AudioToolbox
import AVFoundation
import HPLibRTMP

class LiveAudioAACEncoder: AudioEncoder {

    private let configuration: LiveAudioConfiguration

    weak var delegate: AudioEncoderDelegate?

    private var converter: AudioConverterRef?

    private var leftBuf: UnsafeMutableRawPointer
    private var aacBuf: UnsafeMutableRawPointer
    private var leftLength: Int = 0

    required init(configuration: LiveAudioConfiguration) {
        self.configuration = configuration

        print("LiveAudioAACEncoder init")

        leftBuf = malloc(Int(configuration.bufferLength))
        aacBuf = malloc(Int(configuration.bufferLength))
    }

    deinit {
        free(leftBuf)

        free(aacBuf)
    }

    func encodeAudioData(data: Data, timeStamp: UInt64) {
        let audioData = data as NSData
        if !createAudioConvert() {
            return
        }

        if leftLength + audioData.length >= self.configuration.bufferLength {
            ///<  发送
            let totalSize = leftLength + audioData.length
            let encodeCount = totalSize / configuration.bufferLength
            var totalBuf: UnsafeMutableRawPointer = malloc(totalSize)
            var p = totalBuf

            memset(totalBuf, Int32(totalSize), 0)
            memcpy(totalBuf, leftBuf, leftLength)
            memcpy(totalBuf + leftLength, audioData.bytes, audioData.length)

            for _ in 0 ..< encodeCount {
                encodeBuffer(buf: p, timestamp: timeStamp)
                p += configuration.bufferLength
            }

            leftLength = totalSize % self.configuration.bufferLength
            memset(leftBuf, 0, self.configuration.bufferLength)
            memcpy(leftBuf, totalBuf + (totalSize - leftLength), leftLength)

            free(totalBuf)

            return
        }

        ///< 积累
        memcpy(leftBuf + leftLength, audioData.bytes, audioData.count)
        leftLength += audioData.count
        return
    }

    func stopEncoder() {

    }

    private func encodeBuffer(buf: UnsafeMutableRawPointer, timestamp: UInt64) {
        guard let converter = converter else {
            return
        }
        var inBuffer = AudioBuffer()
        inBuffer.mNumberChannels = 1
        inBuffer.mData = buf
        inBuffer.mDataByteSize = UInt32(configuration.bufferLength)

        var inBufferList = AudioBufferList()
        inBufferList.mNumberBuffers = 1
        var buffers = UnsafeMutableBufferPointer<AudioBuffer>(start: &inBufferList.mBuffers,
                                                              count: Int(inBufferList.mNumberBuffers))
        buffers[0] = inBuffer

        // 初始化一个输出缓冲列表
        var outBufferList = AudioBufferList()
        outBufferList.mNumberBuffers = 1
        let outBuffers = UnsafeMutableBufferPointer<AudioBuffer>(start: &outBufferList.mBuffers,
                                                                 count: Int(outBufferList.mNumberBuffers))
        outBuffers[0].mNumberChannels = inBuffer.mNumberChannels
        outBuffers[0].mDataByteSize = inBuffer.mDataByteSize   // 设置缓冲区大小
        outBuffers[0].mData = aacBuf

        var outputDataPacketSize = UInt32(1)
        let status = AudioConverterFillComplexBuffer(converter, inputDataProc, &inBufferList, &outputDataPacketSize, &outBufferList, nil)
        if status != noErr {
            return
        }

        var audioFrame = AudioFrame()
        audioFrame.timestamp = timestamp
        audioFrame.data = NSData(bytes: aacBuf, length: Int(outBuffers[0].mDataByteSize)) as Data

        if let asc = configuration.asc {
            var exeData = [UInt8]()
            exeData[0] = asc[0]
            exeData[1] = asc[1]
            audioFrame.audioInfo = NSData(bytes: exeData, length: 2) as Data
        }

        delegate?.audioEncoder(encoder: self, audioFrame: audioFrame)
    }

    private let inputDataProc: AudioConverterComplexInputDataProc = { (
        audioConverter,
        ioNumDataPackets,
        ioData,
        ioPacketDesc,
        inUserData ) -> OSStatus in

        guard var bufferList = inUserData?.assumingMemoryBound(to: AudioBufferList.self).pointee else {
            print("AudioBufferList error")
            return noErr
        }
        let buffers = UnsafeMutableBufferPointer<AudioBuffer>(start: &bufferList.mBuffers,
                                                              count: Int(bufferList.mNumberBuffers))

        let dataPtr = UnsafeMutableAudioBufferListPointer(ioData)
        dataPtr[0].mNumberChannels = 1
        dataPtr[0].mData = buffers[0].mData
        dataPtr[0].mDataByteSize = buffers[0].mDataByteSize

        return noErr
    }

    private func createAudioConvert() -> Bool {
        if converter != nil {
            return true
        }

        var inputFormat = AudioStreamBasicDescription()
        inputFormat.mSampleRate = Float64(configuration.audioSampleRate.rawValue)
        inputFormat.mFormatID = kAudioFormatLinearPCM
        inputFormat.mFormatFlags =  kAudioFormatFlagIsSignedInteger | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked
        inputFormat.mChannelsPerFrame = configuration.numberOfChannels
        inputFormat.mFramesPerPacket = 1
        inputFormat.mBitsPerChannel = 16
        inputFormat.mBytesPerFrame = inputFormat.mBitsPerChannel / 8 * inputFormat.mChannelsPerFrame
        inputFormat.mBytesPerPacket = inputFormat.mBytesPerFrame * inputFormat.mFramesPerPacket

        // 输出音频格式
        var outputFormat = AudioStreamBasicDescription()
        memset(&outputFormat, 0, MemoryLayout.size(ofValue: outputFormat))
        outputFormat.mSampleRate = inputFormat.mSampleRate // 采样率保持一致
        outputFormat.mFormatID = kAudioFormatMPEG4AAC // AAC编码 kAudioFormatMPEG4AAC kAudioFormatMPEG4AAC_HE_V2
        outputFormat.mChannelsPerFrame = configuration.numberOfChannels
        outputFormat.mFramesPerPacket = 1024 // AAC一帧是1024个字节

        let subtype = kAudioFormatMPEG4AAC
        let requestedCodecs: [AudioClassDescription] = [
            .init(
                mType: kAudioEncoderComponentType,
                mSubType: subtype,
                mManufacturer: kAppleSoftwareAudioCodecManufacturer),
            .init(
                mType: kAudioEncoderComponentType,
                mSubType: subtype,
                mManufacturer: kAppleHardwareAudioCodecManufacturer)
        ]

        let result = AudioConverterNewSpecific(&inputFormat, &outputFormat, 2, requestedCodecs, &converter)

        if result != noErr {
            return false
        }

        guard let converter = converter else {
            return false
        }

        var outputBitrate = configuration.audioBitRate.rawValue
        let propSize = MemoryLayout.size(ofValue: outputBitrate)

        let setPropertyresult = AudioConverterSetProperty(converter, kAudioConverterEncodeBitRate, UInt32(propSize), &outputBitrate)

        if setPropertyresult != noErr {
            return false
        }

        return true
    }

}
