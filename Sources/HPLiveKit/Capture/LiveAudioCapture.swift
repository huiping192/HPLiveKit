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

let HPAudioComponentFailedToCreateNotification = Notification.Name(rawValue: "AudioComponentFailedToCreateNotification")

protocol AudioCaptureDelegate: class {
    /** LFAudioCapture callback audioData */
    func captureOutput(capture: LiveAudioCapture, audioData: Data)
}

extension LiveAudioCapture: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        var audioBufferList = AudioBufferList()
        var data = Data()
        var blockBuffer: CMBlockBuffer?

      CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: &audioBufferList, bufferListSize: MemoryLayout<AudioBufferList>.size, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &blockBuffer)

        let buffers = UnsafeBufferPointer<AudioBuffer>(start: &audioBufferList.mBuffers, count: Int(audioBufferList.mNumberBuffers))

        for audioBuffer in buffers {
            if muted {
                memset(audioBuffer.mData, 0, Int(audioBuffer.mDataByteSize))
            }

            let frame = audioBuffer.mData?.assumingMemoryBound(to: UInt8.self)
            data.append(frame!, count: Int(audioBuffer.mDataByteSize))
        }
        delegate?.captureOutput(capture: self, audioData: data)
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
                self._running = true

                var categoryOptions: AVAudioSession.CategoryOptions
                if #available(iOS 9.0, *) {
                    categoryOptions = [.defaultToSpeaker, .interruptSpokenAudioAndMixWithOthers]
                } else {
                    categoryOptions = [.defaultToSpeaker]
                }

              try? self.session.setCategory(AVAudioSession.Category.playAndRecord, options: categoryOptions)
                self.captureSession.startRunning()
            }
        }
    }

    private var session: AVAudioSession = .sharedInstance()

    private let taskQueue = DispatchQueue(label: "com.huiping192.HPLiveKit.audioCapture.Queue")

    private var configuration: LiveAudioConfiguration

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

    func configureAudioSession() {
        try? session.setPreferredSampleRate(Double(configuration.audioSampleRate.rawValue))
        var categoryOptions: AVAudioSession.CategoryOptions
        if #available(iOS 9.0, *) {
            categoryOptions = [.defaultToSpeaker, .interruptSpokenAudioAndMixWithOthers]
        } else {
            categoryOptions = [.defaultToSpeaker]
        }
      try? session.setCategory(AVAudioSession.Category.playAndRecord, options: categoryOptions)

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
