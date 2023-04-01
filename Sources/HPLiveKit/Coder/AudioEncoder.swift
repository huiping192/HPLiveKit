//
//  AudioEncoder.swift
//  HPLiveKit
//
//  Created by Huiping Guo on 2020/02/26.
//

import Foundation

protocol AudioEncoderDelegate: AnyObject {
    func audioEncoder(encoder: AudioEncoder, audioFrame: AudioFrame)
}

protocol AudioEncoder: AnyObject {
    var delegate: AudioEncoderDelegate? {
        get
        set
    }

    func encodeAudioData(data: Data, timeStamp: Timestamp)

    func stopEncoder()
}
