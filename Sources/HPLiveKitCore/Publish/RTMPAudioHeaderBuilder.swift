//
//  RTMPAudioHeaderBuilder.swift
//  HPLiveKit
//
//  Created by Huiping Guo on 2025/10/26.
//  Copyright © 2025 Huiping Guo. All rights reserved.
//

import Foundation
import AVFoundation
import HPRTMP

struct RTMPAudioHeaderBuilder {

  static func buildAudioHeader(
    outFormatDescription: CMFormatDescription,
    aacHeader: Data
  ) -> Data? {
    guard let streamBasicDesc = AudioSampleBufferUtils.extractFormat(from: outFormatDescription),
          let mp4Id = MPEG4ObjectID(rawValue: Int(streamBasicDesc.mFormatFlags)) else {
      return nil
    }
    var descData = Data()
    let config = AudioSpecificConfig(
      objectType: mp4Id,
      channelConfig: ChannelConfigType(rawValue: UInt8(streamBasicDesc.mChannelsPerFrame)),
      frequencyType: SampleFrequencyType(value: streamBasicDesc.mSampleRate)
    )

    descData.append(aacHeader)
    descData.write(AudioData.AACPacketType.header.rawValue)
    descData.append(config.encodeData)

    return descData
  }

  static func buildAACHeader(
    outFormatDescription: CMFormatDescription,
    actualBitsPerChannel: UInt32
  ) -> Data? {
    guard let streamBasicDesc = AudioSampleBufferUtils.extractFormat(from: outFormatDescription) else {
      return nil
    }

    let soundType: AudioData.SoundType = streamBasicDesc.mChannelsPerFrame == 1 ? .sndMono : .sndStereo
    let soundSize: AudioData.SoundSize = actualBitsPerChannel <= 8 ? .snd8Bit : .snd16Bit

    let value = (AudioData.SoundFormat.aac.rawValue << 4 |
                 AudioData.SoundRate(value: streamBasicDesc.mSampleRate).rawValue << 2 |
                 soundSize.rawValue << 1 |
                 soundType.rawValue)

    return Data([UInt8(value)])
  }
}
