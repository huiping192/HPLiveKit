//
//  LiveVideoH264Encoder.swift
//  HPLiveKit
//
//  Created by Huiping Guo on 2018/08/20.
//  Copyright © 2018 Huiping Guo. All rights reserved.
//

import Foundation
@preconcurrency import VideoToolbox
import HPRTMP
import UIKit
import os

/// Video H.264 encoder using Swift 6 Actor for thread safety
/// Input: CMSampleBuffer via encode() method (non-blocking)
/// Output: VideoFrame via AsyncStream
actor LiveVideoH264Encoder: VideoEncoder {
  private static let logger = Logger(subsystem: "com.hplivekit", category: "VideoH264Encoder")

  // MARK: - AsyncStream for Input/Output

  /// Input stream: receives CMSampleBuffer from external callers
  private let inputStream: AsyncStream<SampleBufferBox>
  /// Input continuation must be nonisolated(unsafe) because CMSampleBuffer is not Sendable
  /// but we need to yield from nonisolated encode() method
  private let inputContinuation: AsyncStream<SampleBufferBox>.Continuation

  /// Output stream: delivers encoded VideoFrame to subscribers
  private let _outputStream: AsyncStream<VideoFrame>
  /// Output continuation must be nonisolated(unsafe) to be captured in VTCompressionOutputHandler
  private let outputContinuation: AsyncStream<VideoFrame>.Continuation

  /// Public read-only access to output stream
  nonisolated var outputStream: AsyncStream<VideoFrame> {
    _outputStream
  }

  // MARK: - Actor-Isolated State (Thread-Safe)

  private var compressionSession: VTCompressionSession?
  private var frameCount: UInt = 0
  private var sps: Data?
  private var pps: Data?

  private var isBackground: Bool = false
  private let configuration: LiveVideoConfiguration

  private let kLimitToAverageBitRateFactor = 1.5

  private var _currentVideoBitRate: UInt

  /// Current video bit rate in bits per second
  var currentVideoBitRate: UInt {
    _currentVideoBitRate
  }

  /// Processing task that consumes input stream and performs encoding
  /// Must be nonisolated(unsafe) to allow assignment in init
  nonisolated(unsafe) private var processingTask: Task<Void, Never>?

  // MARK: - Initialization

  init(configuration: LiveVideoConfiguration) {
    self.configuration = configuration
    self._currentVideoBitRate = configuration.videoBitRate

    // Create input stream
    (self.inputStream, self.inputContinuation) = AsyncStream.makeStream()

    // Create output stream
    (self._outputStream, self.outputContinuation) = AsyncStream.makeStream()

    // Note: Cannot call actor-isolated methods in init
    // We'll initialize compression session and notifications in processingTask
    // Start processing task (cannot access self.processingTask in nonisolated init)
    let task: Task<Void, Never> = Task { [weak self] in
      await self?.initializeEncoder()
      await self?.processEncodingLoop()
    }
    self.processingTask = task
  }

  deinit {
    // deinit is nonisolated, cannot call actor methods directly
    // Compression session cleanup will be handled by stop() or Task cancellation
    NotificationCenter.default.removeObserver(self)
  }

  // MARK: - Public API

  /// Encodes a video sample buffer (non-blocking, returns immediately)
  /// The sample buffer is yielded to internal processing stream
  nonisolated func encode(sampleBuffer: SampleBufferBox) {
    inputContinuation.yield(sampleBuffer)
  }

  /// Dynamically adjusts the video bit rate
  /// This method is async because it accesses actor-isolated state
  func setVideoBitRate(_ bitRate: UInt) async {
    guard !isBackground else { return }
    guard let compressionSession = compressionSession else { return }

    VTSessionSetProperty(compressionSession, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: bitRate))

    let bytes = Int64(Double(bitRate) * kLimitToAverageBitRateFactor / 8)
    let duration = Int64(1)

    let limit = [bytes, duration] as CFArray
    VTSessionSetProperty(compressionSession, key: kVTCompressionPropertyKey_DataRateLimits, value: limit)
    _currentVideoBitRate = bitRate
  }

  /// Stops the encoder and finishes all streams
  func stop() {
    // Cancel processing task
    processingTask?.cancel()

    // Finish streams
    inputContinuation.finish()
    outputContinuation.finish()

    // Complete and invalidate compression session
    guard let compressionSession = compressionSession else { return }
    VTCompressionSessionCompleteFrames(compressionSession, untilPresentationTimeStamp: CMTime.indefinite)
    VTCompressionSessionInvalidate(compressionSession)
    self.compressionSession = nil
  }

  // MARK: - Private Processing Loop

  /// Initialize encoder (called from processingTask)
  /// This must be called from async context, not from init
  private func initializeEncoder() {
    resetCompressionSession()
    configureNotifications()
  }

  /// Main encoding loop that processes sample buffers from input stream
  private func processEncodingLoop() async {
    for await sampleBuffer in inputStream {
      await encodeSampleBuffer(sampleBuffer)
    }
  }

  /// Encodes a single sample buffer
  private func encodeSampleBuffer(_ sampleBufferBox: SampleBufferBox) async {
    // Skip encoding in background
    guard !isBackground else {
      return
    }
    
    let sampleBuffer = sampleBufferBox.samplebuffer

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

    // Output handler for VideoToolbox
    // Note: This closure runs on encoder's internal thread, not on actor's executor
    // We use nonisolated continuation.yield() to safely send data to output stream
    let outputHandler: VTCompressionOutputHandler = { [outputContinuation, weak self] (status, infoFlags, sampleBuffer) in
      guard let self = self else { return }

      if status != noErr {
        Self.logger.error("Video frame encoding failed with status: \(status)")
        // Reset compression session on error (must use Task to call actor method)
        Task { await self.resetCompressionSession() }
        return
      }

      guard let sampleBuffer = sampleBuffer else { return }

      guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) else { return }
      guard let attachment = (attachments as NSArray)[0] as? NSDictionary else {
        return
      }

      let isKeyframe = !(attachment[kCMSampleAttachmentKey_DependsOnOthers] as? Bool ?? true)
      let format = CMSampleBufferGetFormatDescription(sampleBuffer)
      
      let samplebufferBox = SampleBufferBox(samplebuffer: sampleBuffer)
      Task {
        if let format, isKeyframe {
          await self.receiveSpsAndPpsIfNeeded(format: format)
        }
        if let videoFrame = await self.convertVideoFrame(sampleBufferBox: samplebufferBox, isKeyFrame: isKeyframe) {
          outputContinuation.yield(videoFrame)
        }
      }
    }

    let status = VTCompressionSessionEncodeFrame(compressionSession, imageBuffer: imageBuffer, presentationTimeStamp: presentationTimeStamp, duration: duration, frameProperties: properties as NSDictionary?, infoFlagsOut: &flags, outputHandler: outputHandler)

    if status != noErr {
      Self.logger.error("VTCompressionSessionEncodeFrame failed with status: \(status)")
    }
  }

  // MARK: - Compression Session Management

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
      Self.logger.error("VTCompressionSessionCreate failed with status: \(status)")
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
    let bytes = Int64(Double(_currentVideoBitRate) * kLimitToAverageBitRateFactor / 8)
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

  @objc nonisolated func handleWillEnterBackground() {
    Self.logger.debug("Application entering background - stopping video encoding")
    Task { await setBackgroundState(true) }
  }

  @objc nonisolated func handlewillEnterForeground() {
    Self.logger.debug("Application entering foreground - resuming video encoding")
    Task {
      await resetCompressionSession()
      await setBackgroundState(false)
    }
  }

  private func setBackgroundState(_ isBackground: Bool) {
    self.isBackground = isBackground
  }

  // MARK: - Frame Conversion

  /// Converts a compressed sample buffer to VideoFrame
  /// This method accesses actor-isolated state (sps, pps, frameCount)
  private func convertVideoFrame(sampleBufferBox: SampleBufferBox, isKeyFrame: Bool) -> VideoFrame? {
    let sampleBuffer = sampleBufferBox.samplebuffer
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

    // Log timestamp periodically to verify it starts from 0
    if frameCount % 100 == 0 {
      Self.logger.debug("Frame \(self.frameCount): timestamp=\(timestamp)ms (\(decodeTimeStamp.seconds)s)")
    }

    return VideoFrame(timestamp: timestamp, data: bufferData, header: nil, isKeyFrame: isKeyFrame, compositionTime: compositionTime, sps: sps, pps: pps)
  }

  /// Extracts SPS and PPS from keyframe if not already set
  private func receiveSpsAndPpsIfNeeded(format: CMFormatDescription) {
    // Only extract if we don't have them yet
    guard sps == nil || pps == nil else { return }

    self.sps = receiveParameterSet(formatDescription: format, index: 0)
    self.pps = receiveParameterSet(formatDescription: format, index: 1)
  }

  private func receiveParameterSet(formatDescription: CMFormatDescription, index: Int) -> Data {
    var size = 0
    var parameterSetPointerOut: UnsafePointer<UInt8>?

    let statusCode = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDescription, parameterSetIndex: index, parameterSetPointerOut: &parameterSetPointerOut, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)

    guard let parameterSetPointerOut = parameterSetPointerOut, statusCode == noErr else {
      Self.logger.error("Failed to receive H.264 parameter set with status: \(statusCode)")
      return Data()
    }

    return Data(bytes: parameterSetPointerOut, count: size)
  }

}
