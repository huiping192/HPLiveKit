//
//  CaptureManager.swift
//  HPLiveKit
//
//  Created by Huiping Guo on 2021/11/16.
//

#if canImport(UIKit)
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
      videoCapture.captureDevicePosition = captureDevicePositionFront ? .front : .back
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
  
  deinit {
    invalidate()
  }
  
  /// Stops capturing and releases all resources.
  /// Must be called before deallocation to ensure proper cleanup.
  public func invalidate() {
    // Stop capturing first
    stopCapturing()
    
    // Clear delegate references to prevent retain cycles
    videoCapture.delegate = nil
    audioCapture.delegate = nil
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
#endif // canImport(UIKit)
