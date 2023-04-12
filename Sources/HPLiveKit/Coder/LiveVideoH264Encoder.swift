//
//  LiveVideoH264Encoder.swift
//  HPLiveKit
//
//  Created by Huiping Guo on 2018/08/20.
//  Copyright © 2018 Huiping Guo. All rights reserved.
//

import Foundation
import VideoToolbox
import HPRTMP
import UIKit

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

          VTSessionSetProperty(compressionSession, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: videoBitRate))

            let bytes = Int64(Double(videoBitRate) * kLimitToAverageBitRateFactor / 8)
            let duration = Int64(1)

            let limit = [bytes, duration] as CFArray
          VTSessionSetProperty(compressionSession, key: kVTCompressionPropertyKey_DataRateLimits, value: limit)
            currentVideoBitRate = newValue
        }
    }

    weak var delegate: VideoEncoderDelegate?

    required init(configuration: LiveVideoConfiguration) {
        self.configuration = configuration
        self.currentVideoBitRate = configuration.videoBitRate

        print("LiveVideoH264Encoder init")

        resetCompressionSession()
        configureNotifications()
    }

    deinit {
        if let compressionSession = compressionSession {
          VTCompressionSessionCompleteFrames(compressionSession, untilPresentationTimeStamp: CMTime.invalid)
            VTCompressionSessionInvalidate(compressionSession)

            self.compressionSession = nil
        }

        NotificationCenter.default.removeObserver(self)
    }

    private func resetCompressionSession() {
        if let compressionSession = compressionSession {
          VTCompressionSessionCompleteFrames(compressionSession, untilPresentationTimeStamp: CMTime.invalid)

            VTCompressionSessionInvalidate(compressionSession)
            self.compressionSession = nil
        }

      let status = VTCompressionSessionCreate(allocator: nil, width: Int32(configuration.internalVideoSize.width), height: Int32(configuration.internalVideoSize.height), codecType: kCMVideoCodecType_H264, encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: vtCallback, refcon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()), compressionSessionOut: &compressionSession)

        if status != noErr {
            print("VTCompressionSessionCreate failed!!")
            return
        }

        guard let compressionSession = compressionSession else { return }
      VTSessionSetProperty(compressionSession, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: configuration.videoMaxKeyframeInterval))
      VTSessionSetProperty(compressionSession, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: NSNumber(value: configuration.videoMaxKeyframeInterval / configuration.videoFrameRate))
      VTSessionSetProperty(compressionSession, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: configuration.videoFrameRate))
      VTSessionSetProperty(compressionSession, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: configuration.videoBitRate))

        let bytes = Int64(Double(videoBitRate) * kLimitToAverageBitRateFactor / 8)
        let duration = Int64(1)

        let limit = [bytes, duration] as CFArray
      VTSessionSetProperty(compressionSession, key: kVTCompressionPropertyKey_DataRateLimits, value: limit)

      VTSessionSetProperty(compressionSession, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
      VTSessionSetProperty(compressionSession, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Main_AutoLevel)
      VTSessionSetProperty(compressionSession, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanTrue)
      VTSessionSetProperty(compressionSession, key: kVTCompressionPropertyKey_H264EntropyMode, value: kVTH264EntropyMode_CABAC)

        VTCompressionSessionPrepareToEncodeFrames(compressionSession)
    }

    private func configureNotifications() {
      NotificationCenter.default.addObserver(self, selector: #selector(self.handleWillEnterBackground), name: UIApplication.willResignActiveNotification, object: nil)

      NotificationCenter.default.addObserver(self, selector: #selector(self.handlewillEnterForeground), name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    @objc func handleWillEnterBackground() {
        isBackground = true
    }

    @objc func handlewillEnterForeground() {
        resetCompressionSession()
        isBackground = false
    }

    func encodeVideoData(pixelBuffer: CVPixelBuffer, timeStamp: Timestamp) {
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

      let status = VTCompressionSessionEncodeFrame(compressionSession, imageBuffer: pixelBuffer, presentationTimeStamp: presentationTimeStamp, duration: duration, frameProperties: properties as NSDictionary?, sourceFrameRefcon: time, infoFlagsOut: &flags)

        if status != noErr {
            print("Encode video frame error!!")
            resetCompressionSession()
        }
    }

    func stopEncoder() {
        guard let compressionSession = compressionSession else { return }
      VTCompressionSessionCompleteFrames(compressionSession, untilPresentationTimeStamp: CMTime.indefinite)
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

      guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) as? NSArray else { return }

        guard let attachment = attachments[0] as? NSDictionary else {
            return
        }

        let isKeyframe = !(attachment[kCMSampleAttachmentKey_DependsOnOthers] as? Bool ?? true)

        let timeStamp = Unmanaged<NSNumber>.fromOpaque(sourceFrameRefCon!).takeUnretainedValue()

        let videoEncoder = Unmanaged<LiveVideoH264Encoder>.fromOpaque(outputCallbackRefCon!).takeUnretainedValue()

        if isKeyframe && (videoEncoder.sps == nil || videoEncoder.pps == nil) {
            getSps(sampleBuffer: sampleBuffer, videoEncoder: videoEncoder)
        }

        getFrame(sampleBuffer: sampleBuffer, isKeyFrame: isKeyframe, timeStamp: timeStamp, videoEncoder: videoEncoder)
    }

    static func getFrame(sampleBuffer: CMSampleBuffer, isKeyFrame: Bool, timeStamp: NSNumber, videoEncoder: LiveVideoH264Encoder) {
       
      
      guard let bufferData = CMSampleBufferGetDataBuffer(sampleBuffer)?.data else {
          return
      }
      var videoFrame = VideoFrame()
      
      let presentationTimeStamp = sampleBuffer.presentationTimeStamp
      var decodeTimeStamp = sampleBuffer.decodeTimeStamp
      if decodeTimeStamp == .invalid {
        decodeTimeStamp = presentationTimeStamp
      }
      videoFrame.timestamp = UInt64(decodeTimeStamp.seconds * 1000)
      videoFrame.compositionTime = Int32((decodeTimeStamp.seconds - presentationTimeStamp.seconds) * 1000)
      videoFrame.data = bufferData
      videoFrame.isKeyFrame = isKeyFrame
      videoFrame.sps = videoEncoder.sps
      videoFrame.pps = videoEncoder.pps
      
      videoEncoder.delegate?.videoEncoder(encoder: videoEncoder, frame: videoFrame)
    }

    static func getSps(sampleBuffer: CMSampleBuffer, videoEncoder: LiveVideoH264Encoder) {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }

        // sps
        var sparameterSetSize: size_t = 0
        var sparameterSetCount: size_t = 0

        var sps: UnsafePointer<UInt8>?

      let spsStatusCode = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: &sps, parameterSetSizeOut: &sparameterSetSize, parameterSetCountOut: &sparameterSetCount, nalUnitHeaderLengthOut: nil)

        if spsStatusCode != noErr {
            print("Receive h264 sps error")
            return
        }

        // pps
        var pparameterSetSize: size_t = 0
        var pparameterSetCount: size_t = 0
        var pps: UnsafePointer<UInt8>?
      let ppsStatusCode = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 1, parameterSetPointerOut: &pps, parameterSetSizeOut: &pparameterSetSize, parameterSetCountOut: &pparameterSetCount, nalUnitHeaderLengthOut: nil)

        if ppsStatusCode != noErr {
            print("Receive h264 pps error")
            return
        }

        guard let spsBytes = sps, let ppsBytes = pps else {
            print("Receive h264 sps,pps error")
            return
        }

        videoEncoder.sps = Data(bytes: spsBytes, count: sparameterSetSize)
        videoEncoder.pps = Data(bytes: ppsBytes, count: pparameterSetSize)
    }

}

extension CMBlockBuffer {
  var data: Data? {
    
    var length: Int = 0
    var pointer: UnsafeMutablePointer<Int8>?
    
    guard CMBlockBufferGetDataPointer(self, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
          let p = pointer else {
      return nil
    }
    return Data(bytes: p, count: length)
  }
  
  var length: Int {
    
    return CMBlockBufferGetDataLength(self)
  }
  
}
