//
//  CaptureManager.swift
//  HPLiveKit
//
//  Created by Huiping Guo on 2021/11/16.
//

import Foundation
import UIKit
import CoreMedia

public protocol CaptureManagerDelegate: AnyObject {
  func captureOutput(captureManager: CaptureManager, video: CMSampleBuffer)
  func captureOutput(captureManager: CaptureManager, audio: CMSampleBuffer)
}

public class CaptureManager: NSObject {
  // video, audio configuration
  private let audioConfiguration: LiveAudioConfiguration
  private let videoConfiguration: LiveVideoConfiguration
  
  // video,audio data source
  private let videoCapture: LiveVideoCapture
  private let audioCapture: LiveAudioCapture
  
  weak var delegate: CaptureManagerDelegate?
  
  // TODO: remove preview from CaptureManager
  public var preview: UIView? {
    get {
      videoCapture.preview
    }
    set {
      videoCapture.preview = newValue
    }
  }
  
  public var mute: Bool = false {
    didSet {
      audioCapture.muted = mute
    }
  }
  
  public var captureDevicePositionFront: Bool = true {
    didSet {
      if videoCapture.captureDevicePosition == .front {
        videoCapture.captureDevicePosition = .back
      } else {
        videoCapture.captureDevicePosition = .front
      }
    }
  }

  
  public init(audioConfiguration: LiveAudioConfiguration, videoConfiguration: LiveVideoConfiguration) {
    self.audioConfiguration = audioConfiguration
    self.videoConfiguration = videoConfiguration
    
    videoCapture = LiveVideoCapture(videoConfiguration: videoConfiguration)
    audioCapture = LiveAudioCapture(configuration: audioConfiguration)
    
    super.init()
    
    videoCapture.delegate = self
    audioCapture.delegate = self
  }
  
  public func startCapturing() {
    videoCapture.running = true
    audioCapture.running = true
  }
  
  public func stopCapturing() {
    videoCapture.running = false
    audioCapture.running = false
  }
}

extension CaptureManager: AudioCaptureDelegate, VideoCaptureDelegate {
  func captureOutput(capture: LiveAudioCapture, sampleBuffer: CMSampleBuffer) {
    delegate?.captureOutput(captureManager: self, audio: sampleBuffer)
  }
  
  func captureOutput(capture: LiveVideoCapture, video sampleBuffer: CMSampleBuffer) {
    delegate?.captureOutput(captureManager: self, video: sampleBuffer)
  }
}
