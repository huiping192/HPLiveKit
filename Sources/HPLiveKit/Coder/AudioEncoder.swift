//
//  AudioEncoder.swift
//  HPLiveKit
//
//  Created by Huiping Guo on 2020/02/26.
//

import Foundation

protocol AudioEncoderDelegate: class {
    func audioEncoder(encoder: AudioEncoder, audioFrame: AudioFrame)
}

protocol AudioEncoder: class {

    weak var delegate: AudioEncoderDelegate? {
        get
        set
    }

    func encodeAudioData(data: Data, timeStamp: Timestamp)

    func stopEncoder()
}
