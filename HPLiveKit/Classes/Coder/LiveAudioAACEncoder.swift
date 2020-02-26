//
//  LiveAudioAACEncoder.swift
//  HPLiveKit
//
//  Created by Huiping Guo on 2018/08/20.
//  Copyright © 2018 Huiping Guo. All rights reserved.
//

import Foundation
import AudioToolbox
import AVFoundation

class LiveAudioAACEncoder: AudioEncoder {

    private let configuration: LiveAudioConfiguration

    weak var delegate: AudioEncoderDelegate?

    private var converter: AudioConverterRef?

    required init(configuration: LiveAudioConfiguration) {
        self.configuration = configuration

        print("LiveAudioAACEncoder init")

    }

    func encodeAudioData(data: Data, timeStamp: UInt64) {

    }

    func stopEncoder() {

    }
}
