//
//  VideoCapture.swift
//  HPLiveKit
//
//  Created by Huiping Guo on 2018/08/20.
//  Copyright © 2018 Huiping Guo. All rights reserved.
//

import Foundation
import AVFoundation
import UIKit
import CoreVideo

private class PreviewView: UIView {
  override class var layerClass: AnyClass {
    return AVCaptureVideoPreviewLayer.self
  }
  
  var videoPreviewLayer: AVCaptureVideoPreviewLayer? {
    return layer as? AVCaptureVideoPreviewLayer
  }
}

protocol VideoCaptureDelegate: AnyObject {
  func captureOutput(capture: LiveVideoCapture, video sampleBuffer: CMSampleBuffer)
}

extension LiveVideoCapture: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
  func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
    self.delegate?.captureOutput(capture: self, video: sampleBuffer)
  }
}

class LiveVideoCapture: NSObject {
  
  private let captureSession = AVCaptureSession()
  
  private var videoDevice: AVCaptureDevice?
  private var videoInput: AVCaptureDeviceInput?
  
  private let videoCaptureQueue = DispatchQueue(label: "com.huiping192.HPLiveKit.VideoCaptureQueue")
  
  private var previewVideoView: PreviewView?
  
  private func configureVideo() {
    guard let videoDevice = frontVideoDevice else {
      fatalError("[HPLiveKit] Can not found front video device!")
    }
    guard let videoInput = try? AVCaptureDeviceInput.init(device: videoDevice) else {
      fatalError("[HPLiveKit] Init video CaptureDeviceInput failed!")
    }
    
    if captureSession.canAddInput(videoInput) {
      captureSession.addInput(videoInput)
    }
    
    self.videoDevice = videoDevice
    self.videoInput = videoInput
    
    let output = AVCaptureVideoDataOutput()
    output.videoSettings = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as [String: Any]
    output.setSampleBufferDelegate(self, queue: videoCaptureQueue)
    
    if captureSession.canAddOutput(output) {
      captureSession.addOutput(output)
    }
    
    // 视频输出的方向
    let videoConnection = output.connection(with: .video)
    videoConnection?.videoOrientation = .portrait
  }
  
  private func configurePreview() {
    let previewVideoView = PreviewView(frame: CGRect.zero)
    previewVideoView.videoPreviewLayer?.session = captureSession
    
    self.previewVideoView = previewVideoView
  }
  
  public var preview: UIView? {
    get {
      return previewVideoView?.superview
    }
    set {
      if previewVideoView?.superview != nil {
        previewVideoView?.removeFromSuperview()
      }
      
      if let perview = newValue, let previewVideoView = previewVideoView {
        perview.insertSubview(previewVideoView, at: 0)
        
        previewVideoView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
          perview.topAnchor.constraint(equalTo: previewVideoView.topAnchor),
          perview.rightAnchor.constraint(equalTo: previewVideoView.rightAnchor),
          perview.leftAnchor.constraint(equalTo: previewVideoView.leftAnchor),
          perview.bottomAnchor.constraint(equalTo: previewVideoView.bottomAnchor)
        ])
      }
    }
  }
  
  var captureDevicePosition: AVCaptureDevice.Position? {
    get {
      return videoDevice?.position ?? .unspecified
    }
    set {
      guard newValue != videoDevice?.position else {
        return
      }
      
      if newValue == .unspecified { return }
                  
      guard let videoDevice = newValue == .front ? frontVideoDevice : backVideoDevice else {
        fatalError("[HPLiveKit] Can not found font video device!")
      }
      guard let videoInput = try? AVCaptureDeviceInput.init(device: videoDevice) else {
        fatalError("[HPLiveKit] Init video CaptureDeviceInput failed!")
      }
      
      captureSession.beginConfiguration()
      
      if let oldInput = self.videoInput {
        captureSession.removeInput(oldInput)
      }
      if captureSession.canAddInput(videoInput) {
        captureSession.addInput(videoInput)
      }
      
      if let videoDataOutput = captureSession.outputs.compactMap({ $0 as? AVCaptureVideoDataOutput }).first,
         let connection = videoDataOutput.connection(with: .video) {
        if connection.isVideoOrientationSupported {
          connection.videoOrientation = .portrait
        }
      }
      
      captureSession.commitConfiguration()
      self.videoDevice = videoDevice
      self.videoInput = videoInput
      
      videoFrameRate = Int32(videoConfiguration.videoFrameRate)
    }
  }
  
  weak var delegate: VideoCaptureDelegate?
  
  fileprivate var videoConfiguration: LiveVideoConfiguration
  
  init(videoConfiguration: LiveVideoConfiguration) {
    self.videoConfiguration = videoConfiguration
    
    super.init()
    
    configureNotifications()
    configureVideo()
    configurePreview()
  }
  
  deinit {
    UIApplication.shared.isIdleTimerDisabled = false
    NotificationCenter.default.removeObserver(self)
    
    captureSession.stopRunning()
    
    previewVideoView?.removeFromSuperview()
    previewVideoView = nil
  }
  
  var running: Bool = false {
    didSet {
      guard running != oldValue else { return }
      if running {
        UIApplication.shared.isIdleTimerDisabled = true
        DispatchQueue.global(qos: .default).async {
          self.captureSession.startRunning()
        }
      } else {
        UIApplication.shared.isIdleTimerDisabled = false
        captureSession.stopRunning()
      }
    }
  }
  
  private var _frameRate: Int32 = 0
  var videoFrameRate: Int32 {
    get {
      return _frameRate
    }
    set {
      guard newValue > 0, newValue != _frameRate else { return }
      guard let device = videoDevice  else { return }
      do {
        try device.lockForConfiguration()
        
        device.activeVideoMinFrameDuration = CMTimeMake(value: 1, timescale: newValue)
        device.activeVideoMaxFrameDuration = CMTimeMake(value: 1, timescale: newValue)
        
        device.unlockForConfiguration()
        
        _frameRate = newValue
      } catch {
        print("[HPLiveKit] Setting frame rate failed! frame raate: \(newValue)")
      }
    }
  }
  
}

// notification
extension LiveVideoCapture {
  
  func configureNotifications() {
    NotificationCenter.default.addObserver(self, selector: #selector(handleWillEnterBackground), name: UIApplication.willResignActiveNotification, object: nil)
    
    NotificationCenter.default.addObserver(self, selector: #selector(handleWillEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
  }
  
  @objc func handleWillEnterBackground() {
    UIApplication.shared.isIdleTimerDisabled = false
    
    captureSession.stopRunning()
  }
  
  @objc func handleWillEnterForeground() {
    DispatchQueue.global(qos: .default).async {
      self.captureSession.startRunning()
    }
    
    UIApplication.shared.isIdleTimerDisabled = true
  }
}

extension LiveVideoCapture {
  private var frontVideoDevice: AVCaptureDevice? {
    AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .front).devices.first
  }
  
  private var backVideoDevice: AVCaptureDevice? {
    AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .back).devices.first
  }
}
