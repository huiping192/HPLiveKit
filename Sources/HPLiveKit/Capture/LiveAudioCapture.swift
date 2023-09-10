//
//  AudioCapture.swift
//  HPLiveKit
//
//  Created by Huiping Guo on 2018/08/20.
//  Copyright © 2018 Huiping Guo. All rights reserved.
//

import Foundation
import AudioToolbox
import AVFoundation

protocol AudioCaptureDelegate: AnyObject {
  func captureOutput(capture: LiveAudioCapture, sampleBuffer: CMSampleBuffer)
}

extension LiveAudioCapture: AVCaptureAudioDataOutputSampleBufferDelegate {
  func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
    if muted {
      muteSampleBuffer(sampleBuffer: sampleBuffer)
    }
    delegate?.captureOutput(capture: self, sampleBuffer: sampleBuffer)
  }
  
  private func muteSampleBuffer(sampleBuffer: CMSampleBuffer) {
    var audioBufferList = AudioBufferList()
    var blockBuffer: CMBlockBuffer?
    
    // 获取音频缓冲区列表
    CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: &audioBufferList, bufferListSize: MemoryLayout<AudioBufferList>.size, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &blockBuffer)
    
    let buffer: AudioBuffer = audioBufferList.mBuffers
    
    // 遍历音频缓冲区，将数据设置为0
    if let data = buffer.mData {
      let byteCount = Int(buffer.mDataByteSize)
      let pointer = data.bindMemory(to: UInt8.self, capacity: byteCount)
      for i in 0..<byteCount {
        pointer[i] = 0
      }
    }
  }
}

class LiveAudioCapture: NSObject {
  
  let captureSession = AVCaptureSession()
  
  weak var delegate: AudioCaptureDelegate?
  
  /** The muted control callbackAudioData,muted will memset 0.*/
  var muted: Bool = false
  
  private var _running: Bool = false
  /** The running control start capture or stop capture*/
  var running: Bool {
    get {
      _running
    }
    set {
      guard newValue != _running else { return }
      
      if !newValue {
        taskQueue.async { [weak self] in
          self?._running = false
          self?.captureSession.stopRunning()
        }
        return
      }
      
      taskQueue.async { [weak self] in
        guard let self = self else { return }
        self.captureSession.startRunning()
        self._running = true
      }
    }
  }
  
  private var session: AVAudioSession = .sharedInstance()
  
  private let taskQueue = DispatchQueue(label: "com.huiping192.HPLiveKit.audioCapture.Queue")
  
  private let configuration: LiveAudioConfiguration
  
  init(configuration: LiveAudioConfiguration) {
    self.configuration = configuration
    
    super.init()
    
    configureAudioSession()
    configureAudio()
  }
  
  deinit {
    taskQueue.sync {
      self.running = false
    }
  }
  
}

extension LiveAudioCapture {
  private func configureAudioSession() {
    try? session.setPreferredSampleRate(Double(configuration.audioSampleRate.rawValue))
    try? session.setCategory(AVAudioSession.Category.playAndRecord, options: [.defaultToSpeaker, .interruptSpokenAudioAndMixWithOthers])
    
    try? session.setActive(true, options: [.notifyOthersOnDeactivation])
    try? session.setActive(true)
  }
  
  private func configureAudio() {
    guard let audioDevice = AVCaptureDevice.default(for: .audio) else {
      fatalError("[HPLiveKit] Can not found audio device!")
    }
    guard let audioDeviceInput = try? AVCaptureDeviceInput.init(device: audioDevice) else {
      fatalError("[HPLiveKit] Init audio CaptureDeviceInput failed!")
    }
    
    if captureSession.canAddInput(audioDeviceInput) {
      captureSession.addInput(audioDeviceInput)
    }
    
    let audioOutput = AVCaptureAudioDataOutput()
    audioOutput.setSampleBufferDelegate(self, queue: taskQueue)
    
    if captureSession.canAddOutput(audioOutput) {
      captureSession.addOutput(audioOutput)
    }
  }
  
}
