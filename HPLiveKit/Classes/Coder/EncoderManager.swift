//
//  EncoderManager.swift
//  HPLiveKit
//
//  Created by Huiping Guo on 2021/11/16.
//

import Foundation

protocol EncoderManagerDelegate: class {
    func encodeOutput(encoderManager: EncoderManager, audioFrame: AudioFrame)
    func encodeOutput(encoderManager: EncoderManager, videoFrame: VideoFrame)
}

class EncoderManager: NSObject {

    // video,audio encoder
    private let videoEncoder: VideoEncoder
    private let audioEncoder: AudioEncoder

    public weak var delegate: EncoderManagerDelegate?

    public var videoBitRate: UInt {
        get {
            videoEncoder.videoBitRate
        }
        set {
            videoEncoder.videoBitRate = newValue
        }
    }

    public init(audioConfiguration: LiveAudioConfiguration, videoConfiguration: LiveVideoConfiguration) {
        videoEncoder = LiveVideoH264Encoder(configuration: videoConfiguration)
        audioEncoder = LiveAudioAACEncoder(configuration: audioConfiguration)

        super.init()

        videoEncoder.delegate = self
        audioEncoder.delegate = self
    }

    public func encodeAudio(data: Data) {
        audioEncoder.encodeAudioData(data: data, timeStamp: .now)
    }

    public func encodeVideo(pixelBuffer: CVPixelBuffer) {
        videoEncoder.encodeVideoData(pixelBuffer: pixelBuffer, timeStamp: .now)
    }
}

extension EncoderManager: AudioEncoderDelegate, VideoEncoderDelegate {
    func audioEncoder(encoder: AudioEncoder, audioFrame: AudioFrame) {
        delegate?.encodeOutput(encoderManager: self, audioFrame: audioFrame)
    }

    func videoEncoder(encoder: VideoEncoder, frame: VideoFrame) {
        delegate?.encodeOutput(encoderManager: self, videoFrame: frame)
    }
}
