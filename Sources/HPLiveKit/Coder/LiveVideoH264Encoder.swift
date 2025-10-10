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

class LiveVideoH264Encoder: VideoEncoder, @unchecked Sendable {
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
      
      VTSessionSetProperty(compressionSession, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: newValue))
      
      let bytes = Int64(Double(newValue) * kLimitToAverageBitRateFactor / 8)
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
    invalidataCompressionSessionIfNeeded()
    
    NotificationCenter.default.removeObserver(self)
  }
  
  private func invalidataCompressionSessionIfNeeded() {
    guard let compressionSession = compressionSession else { return }
    VTCompressionSessionCompleteFrames(compressionSession, untilPresentationTimeStamp: CMTime.invalid)
    VTCompressionSessionInvalidate(compressionSession)
    self.compressionSession = nil
  }
  
  private func resetCompressionSession() {
    invalidataCompressionSessionIfNeeded()
    
    // Create a new H.264 compression session with specified configurations
    let status = VTCompressionSessionCreate(
      allocator: nil,
      width: Int32(configuration.internalVideoSize.width),
      height: Int32(configuration.internalVideoSize.height),
      codecType: kCMVideoCodecType_H264,
      encoderSpecification: nil,
      imageBufferAttributes: nil,
      compressedDataAllocator: nil,
      outputCallback: nil,
      refcon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
      compressionSessionOut: &compressionSession
    )
    
    // Check if the compression session creation was successful
    if status != noErr {
      print("VTCompressionSessionCreate failed!!")
      return
    }
    
    // Ensure compression session exists before proceeding
    guard let compressionSession = compressionSession else { return }
    
    // Set the maximum keyframe interval (e.g., keyframe every N frames)
    VTSessionSetProperty(compressionSession, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: configuration.videoMaxKeyframeInterval))
    
    // Set the maximum keyframe interval duration based on frame rate
    VTSessionSetProperty(compressionSession, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: NSNumber(value: configuration.videoMaxKeyframeInterval / configuration.videoFrameRate))
    
    // Set the expected frame rate
    VTSessionSetProperty(compressionSession, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: configuration.videoFrameRate))
    
    // Set the average bit rate
    VTSessionSetProperty(compressionSession, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: configuration.videoBitRate))
    
    // Limit the data rate
    let bytes = Int64(Double(videoBitRate) * kLimitToAverageBitRateFactor / 8)
    let duration = Int64(1)
    let limit = [bytes, duration] as CFArray
    VTSessionSetProperty(compressionSession, key: kVTCompressionPropertyKey_DataRateLimits, value: limit)
    
    // Enable real-time encoding
    VTSessionSetProperty(compressionSession, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
    
    // Set the H.264 profile level
    VTSessionSetProperty(compressionSession, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Main_AutoLevel)
    
    // Disable frame reordering for more efficient encoding but potentially lower quality
    VTSessionSetProperty(compressionSession, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
    
    // Set entropy mode for H.264 encoding (CABAC = Context-Based Adaptive Binary Arithmetic Coding)
    VTSessionSetProperty(compressionSession, key: kVTCompressionPropertyKey_H264EntropyMode, value: kVTH264EntropyMode_CABAC)
    
    // Prepare the encoder for encoding frames
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
  
  func encode(sampleBuffer: CMSampleBuffer) {
    guard !isBackground else { return }
    guard let compressionSession = compressionSession else { return }
    guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    
    frameCount += 1
    
    let presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    
    let duration = CMSampleBufferGetDuration(sampleBuffer)
    
    var flags: VTEncodeInfoFlags = .init()
    
    var properties: [String: Any]? = nil
    
    if frameCount % configuration.videoMaxKeyframeInterval == 0 {
      properties = [
        kVTEncodeFrameOptionKey_ForceKeyFrame as String: true
      ]
    }
    
    let outputHandler: VTCompressionOutputHandler = { [weak self] (status, infoFlags, sampleBuffer) in
      guard let self = self else { return }
      
      if status != noErr {
        print("Encode video frame error!!")
        self.resetCompressionSession()
      }
      
      guard let sampleBuffer = sampleBuffer else { return }
      
      guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) else { return }
      guard let attachment = (attachments as NSArray)[0] as? NSDictionary else {
        return
      }
      
      let isKeyframe = !(attachment[kCMSampleAttachmentKey_DependsOnOthers] as? Bool ?? true)
      
      if isKeyframe && (self.sps == nil || self.pps == nil) {
        self.receiveSpsAndPps(sampleBuffer: sampleBuffer)
      }
      
      if let videoFrame = self.convertVideoFrame(sampleBuffer: sampleBuffer, isKeyFrame: isKeyframe) {
        print("[encoder] video frame")
        self.delegate?.videoEncoder(encoder: self, frame: videoFrame)
      }
    }
    
    let status =  VTCompressionSessionEncodeFrame(compressionSession, imageBuffer: imageBuffer, presentationTimeStamp: presentationTimeStamp, duration: duration, frameProperties: properties as NSDictionary?, infoFlagsOut: &flags, outputHandler: outputHandler)
    
    if status != noErr {
      print("Encode video frame error!!")
    }
  }
  
  func stop() {
    guard let compressionSession = compressionSession else { return }
    VTCompressionSessionCompleteFrames(compressionSession, untilPresentationTimeStamp: CMTime.indefinite)
  }
  
  private func convertVideoFrame(sampleBuffer: CMSampleBuffer, isKeyFrame: Bool) -> VideoFrame? {
    guard let bufferData = CMSampleBufferGetDataBuffer(sampleBuffer)?.data else {
      return nil
    }
    
    let presentationTimeStamp = sampleBuffer.presentationTimeStamp
    var decodeTimeStamp = sampleBuffer.decodeTimeStamp
    if decodeTimeStamp == .invalid {
      decodeTimeStamp = presentationTimeStamp
    }
    let timestamp = UInt64(decodeTimeStamp.seconds * 1000)
    let compositionTime = Int32((presentationTimeStamp.seconds - decodeTimeStamp.seconds) * 1000)
    
    return VideoFrame(timestamp: timestamp, data: bufferData, header: nil, isKeyFrame: isKeyFrame, compositionTime: compositionTime, sps: sps, pps: pps)
  }
  
  private func receiveSpsAndPps(sampleBuffer: CMSampleBuffer) {
    guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
    
    self.sps = receiveParameterSet(formatDescription: format, index: 0)
    self.pps = receiveParameterSet(formatDescription: format, index: 1)
  }
  
  private func receiveParameterSet(formatDescription: CMFormatDescription, index: Int) -> Data {
    var size = 0
    var parameterSetPointerOut: UnsafePointer<UInt8>?
    
    let statusCode = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDescription, parameterSetIndex: index, parameterSetPointerOut: &parameterSetPointerOut, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
    
    guard let parameterSetPointerOut = parameterSetPointerOut, statusCode == noErr else {
      print("Receive h264 ParameterSet error, \(statusCode)")
      return Data()
    }
    
    return Data(bytes: parameterSetPointerOut, count: size)
  }
  
}

