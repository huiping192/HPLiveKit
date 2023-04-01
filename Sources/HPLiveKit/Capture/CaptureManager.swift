//
//  CaptureManager.swift
//  HPLiveKit
//
//  Created by Huiping Guo on 2021/11/16.
//

import Foundation
import UIKit

public protocol CaptureManagerDelegate: AnyObject {
    func captureOutput(captureManager: CaptureManager, video: CVPixelBuffer)
    func captureOutput(captureManager: CaptureManager, audio: Data)
}

public class CaptureManager: NSObject {
    // video, audio configuration
    private let audioConfiguration: LiveAudioConfiguration
    private let videoConfiguration: LiveVideoConfiguration

    // video,audio data source
    private let videoCapture: LiveVideoCapture
    private let audioCapture: LiveAudioCapture

    weak var delegate: CaptureManagerDelegate?

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
    func captureOutput(capture: LiveAudioCapture, audioData: Data) {
        delegate?.captureOutput(captureManager: self, audio: audioData)
    }

    func captureOutput(capture: LiveVideoCapture, pixelBuffer: CVPixelBuffer) {
        delegate?.captureOutput(captureManager: self, video: pixelBuffer)
    }
}
