//
//  EncoderManager.swift
//  HPLiveKit
//
//  Created by Huiping Guo on 2021/11/16.
//

import Foundation
import CoreVideo
import CoreMedia

public protocol EncoderManagerDelegate: class {
    func encodeOutput(encoderManager: EncoderManager, audioFrame: AudioFrame)
    func encodeOutput(encoderManager: EncoderManager, videoFrame: VideoFrame)
}

public class EncoderManager: NSObject {

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

  public func encodeAudio(sampleBuffer: CMSampleBuffer) {
    audioEncoder.encodeAudioData(sampleBuffer: sampleBuffer)
    }

    public func encodeVideo(sampleBuffer: CMSampleBuffer) {
        videoEncoder.encodeVideoData(sampleBuffer: sampleBuffer)
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
