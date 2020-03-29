//
//  AudioEncoder.swift
//  HPLiveKit
//
//  Created by Huiping Guo on 2020/02/26.
//

import Foundation
import HPLibRTMP

protocol AudioEncoderDelegate: class {
    func audioEncoder(encoder: AudioEncoder, audioFrame: HPAudioFrame)
}

protocol AudioEncoder: class {

    weak var delegate: AudioEncoderDelegate? {
        get
        set
    }

    func encodeAudioData(data: Data, timeStamp: UInt64)

    func stopEncoder()
}
