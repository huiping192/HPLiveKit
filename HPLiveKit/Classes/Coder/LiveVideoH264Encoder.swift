//
//  LiveVideoH264Encoder.swift
//  HPLiveKit
//
//  Created by Huiping Guo on 2018/08/20.
//  Copyright © 2018 Huiping Guo. All rights reserved.
//

import Foundation
import VideoToolbox

class LiveVideoH264Encoder: VideoEncoder {
    private var compressionSession: VTCompressionSession?
    private var frameCount: UInt = 0
    private var sps: Data?
    private var pps: Data?

    private var isBackground: Bool = false
    private let configuration: LiveVideoConfiguration

    private let kLimitToAverageBitRateFactor = 1.5

    private var currentVideoBitRate: UInt
    var videoBitRate: UInt {
        get {
            return currentVideoBitRate
        }

        set {
            guard !isBackground else { return }

            guard let compressionSession = compressionSession else { return }

            VTSessionSetProperty(compressionSession, kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: videoBitRate))

            let bytes = Int64(Double(videoBitRate) * kLimitToAverageBitRateFactor / 8)
            let duration = Int64(1)

            let limit = [bytes, duration] as CFArray
            VTSessionSetProperty(compressionSession, kVTCompressionPropertyKey_DataRateLimits, limit)
            currentVideoBitRate = newValue
        }
    }

    weak var delegate: VideoEncodingDelegate?

    required init(configuration: LiveVideoConfiguration) {
        self.configuration = configuration
        self.currentVideoBitRate = configuration.videoBitRate

        print("LiveVideoH264Encoder init")

        resetCompressionSession()
        configureNotifications()
    }

    deinit {
        if let compressionSession = compressionSession {
            VTCompressionSessionCompleteFrames(compressionSession, kCMTimeInvalid)
            VTCompressionSessionInvalidate(compressionSession)

            self.compressionSession = nil
        }

        NotificationCenter.default.removeObserver(self)
    }

    private func resetCompressionSession() {
        if let compressionSession = compressionSession {
            VTCompressionSessionCompleteFrames(compressionSession, kCMTimeInvalid)

            VTCompressionSessionInvalidate(compressionSession)
            self.compressionSession = nil
        }

        let status = VTCompressionSessionCreate(nil, Int32(configuration.internalVideoSize.width), Int32(configuration.internalVideoSize.height), kCMVideoCodecType_H264, nil, nil, nil, vtCallback, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()), &compressionSession)

        if status != noErr {
            print("VTCompressionSessionCreate failed!!")
            return
        }

        guard let compressionSession = compressionSession else { return }
        VTSessionSetProperty(compressionSession, kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: configuration.videoMaxKeyframeInterval))
        VTSessionSetProperty(compressionSession, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: configuration.videoMaxKeyframeInterval / configuration.videoFrameRate))
        VTSessionSetProperty(compressionSession, kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: configuration.videoFrameRate))
        VTSessionSetProperty(compressionSession, kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: configuration.videoBitRate))

        let bytes = Int64(Double(videoBitRate) * kLimitToAverageBitRateFactor / 8)
        let duration = Int64(1)

        let limit = [bytes, duration] as CFArray
        VTSessionSetProperty(compressionSession, kVTCompressionPropertyKey_DataRateLimits, limit)

        VTSessionSetProperty(compressionSession, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        VTSessionSetProperty(compressionSession, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Main_AutoLevel)
        VTSessionSetProperty(compressionSession, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanTrue)
        VTSessionSetProperty(compressionSession, kVTCompressionPropertyKey_H264EntropyMode, kVTH264EntropyMode_CABAC)

        VTCompressionSessionPrepareToEncodeFrames(compressionSession)
    }

    private func configureNotifications() {
        NotificationCenter.default.addObserver(self, selector: #selector(self.handleWillEnterBackground), name: Notification.Name.UIApplicationWillResignActive, object: nil)

        NotificationCenter.default.addObserver(self, selector: #selector(self.handlewillEnterForeground), name: Notification.Name.UIApplicationDidBecomeActive, object: nil)
    }

    @objc func handleWillEnterBackground() {
        isBackground = true
    }

    @objc func handlewillEnterForeground() {
        resetCompressionSession()
        isBackground = false
    }

    func encodeVideoData(pixelBuffer: CVPixelBuffer, timeStamp: UInt64) {
        guard !isBackground else { return }
        guard let compressionSession = compressionSession else { return }

        frameCount += 1
        let presentationTimeStamp = CMTime(value: Int64(frameCount), timescale: Int32(configuration.videoFrameRate))

        let duration = CMTime(value: 1, timescale: Int32(configuration.videoFrameRate))

        var flags: VTEncodeInfoFlags = .init()

        var properties: [String: Any]?

        if frameCount % configuration.videoMaxKeyframeInterval == 0 {
            properties = [
                kVTEncodeFrameOptionKey_ForceKeyFrame as String: true
            ]
        }

        let timeNumber = NSNumber(value: timeStamp)
        let time = UnsafeMutableRawPointer(Unmanaged.passRetained(timeNumber).toOpaque())

        let status = VTCompressionSessionEncodeFrame(compressionSession, pixelBuffer, presentationTimeStamp, duration, properties as NSDictionary?, time, &flags)

        if status != noErr {
            print("Encode video frame error!!")
            resetCompressionSession()
        }
    }

    func stopEncoder() {
        guard let compressionSession = compressionSession else { return }
        VTCompressionSessionCompleteFrames(compressionSession, kCMTimeIndefinite)
    }

    private var vtCallback: VTCompressionOutputCallback = { (
        outputCallbackRefCon,
        sourceFrameRefCon,
        status,
        infoFlags,
        sampleBuffer ) -> Void in

        if status != noErr {
            print("Video encoder failed!!")
            return
        }

        guard let sampleBuffer = sampleBuffer else { return }

        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, true) as? NSArray else { return }

        guard let attachment = attachments[0] as? NSDictionary else {
            return
        }

        let isKeyframe = !(attachment[kCMSampleAttachmentKey_DependsOnOthers] as? Bool ?? true)
        guard let timeStamp = UnsafeMutablePointer<NSNumber>(OpaquePointer(sourceFrameRefCon))?.pointee else {
            fatalError("Receive video frame timeStamp error!!")
        }

        guard let videoEncoder = UnsafeMutablePointer<LiveVideoH264Encoder>(OpaquePointer(outputCallbackRefCon))?.pointee else {
            fatalError("Receive LiveVideoH264Encoder instance error!!")
        }

        if isKeyframe && videoEncoder.sps != nil {
            getSps(sampleBuffer: sampleBuffer, videoEncoder: videoEncoder)
        }

        getFrame(sampleBuffer: sampleBuffer, isKeyFrame: isKeyframe, timeStamp: timeStamp, videoEncoder: videoEncoder)
    }

    static func getFrame(sampleBuffer: CMSampleBuffer, isKeyFrame: Bool, timeStamp: NSNumber, videoEncoder: LiveVideoH264Encoder) {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            print("Receive databuffer error!!")
            return
        }

        var length: size_t = 0
        var totalLength: size_t = 0
        var dataPointer: UnsafeMutablePointer<Int8>?

        let statusCodeRet = CMBlockBufferGetDataPointer(dataBuffer, 0, &length, &totalLength, &dataPointer)

        if statusCodeRet != noErr {
            print("Receive data pointer error!!")
            return
        }

        guard let ptr = dataPointer else {
            print("Receive data pointer is nil!!")
            return
        }

        var bufferOffset: size_t = 0
        let AVCCHeaderLength: size_t = 4

        while bufferOffset < totalLength - AVCCHeaderLength {
            // Read the NAL unit length
            var NALUnitLength: UInt32 = 0
            memcpy(&NALUnitLength, ptr + bufferOffset, AVCCHeaderLength)

            NALUnitLength = CFSwapInt32BigToHost(NALUnitLength)

            let data = Data(bytes: ptr + bufferOffset + AVCCHeaderLength, count: Int(NALUnitLength))
            var videoFrame = VideoFrame()

            videoFrame.timestamp = timeStamp.uint64Value
            videoFrame.data = data
            videoFrame.isKeyFrame = isKeyFrame
            videoFrame.sps = videoEncoder.sps
            videoFrame.pps = videoEncoder.pps

            videoEncoder.delegate?.videoEncoder(encoder: videoEncoder, frame: videoFrame)

            bufferOffset += AVCCHeaderLength + Int(NALUnitLength)
        }

    }

    static func getSps(sampleBuffer: CMSampleBuffer, videoEncoder: LiveVideoH264Encoder) {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }

        // sps
        var sparameterSetSize: size_t = 0
        var sparameterSetCount: size_t = 0

        var sps: UnsafePointer<UInt8>?

        let spsStatusCode = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, 0, &sps, &sparameterSetSize, &sparameterSetCount, nil)

        if spsStatusCode != noErr {
            print("Receive h264 sps error")
            return
        }

        // pps
        var pparameterSetSize: size_t = 0
        var pparameterSetCount: size_t = 0
        var pps: UnsafePointer<UInt8>?
        let ppsStatusCode = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, 0, &pps, &sparameterSetSize, &sparameterSetCount, nil)

        if ppsStatusCode != noErr {
            print("Receive h264 pps error")
            return
        }

        guard let spsBytes = sps, let ppsBytes = pps else {
            print("Receive h264 sps,pps error")
            return
        }

        videoEncoder.sps = Data(bytes: spsBytes, count: sparameterSetSize)
        videoEncoder.sps = Data(bytes: ppsBytes, count: pparameterSetSize)
    }

}
