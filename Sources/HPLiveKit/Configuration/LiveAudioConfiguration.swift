//
//  LiveAudioConfiguration.swift
//  HPLiveKit
//
//  Created by Huiping Guo on 2018/08/20.
//  Copyright © 2018 Huiping Guo. All rights reserved.
//

import Foundation

// 音频码率
public enum LiveAudioBitRate: Int {
    /// 32Kbps 音频码率
    case a32Kbps = 32000
    /// 64Kbps 音频码率
    case a64Kbps = 64000
    /// 96Kbps 音频码率
    case a96Kbps = 96000
    /// 128Kbps 音频码率
    case a128Kbps = 128000
}

///// 音频采样率
public enum LiveAudioSampleRate: Int {
    /// 16KHz 采样率
    case s16000Hz = 16000
    /// 44.1KHz 采样率
    case s44100Hz = 44100
    /// 48KHz 采样率
    case s48000Hz = 48000

    var sampleRateIndex: UInt8 {
        var sampleRateIndex: UInt8 = 0
        switch self.rawValue {
        case 96000:
            sampleRateIndex = 0
        case 88200:
            sampleRateIndex = 1
        case 64000:
            sampleRateIndex = 2
        case 48000:
            sampleRateIndex = 3
        case 44100:
            sampleRateIndex = 4
        case 32000:
            sampleRateIndex = 5
        case 24000:
            sampleRateIndex = 6
        case 22050:
            sampleRateIndex = 7
        case 16000:
            sampleRateIndex = 8
        case 12000:
            sampleRateIndex = 9
        case 11025:
            sampleRateIndex = 10
        case 8000:
            sampleRateIndex = 11
        case 7350:
            sampleRateIndex = 12
        default:
            sampleRateIndex = 15
        }

        return sampleRateIndex
    }
}

public enum LiveAudioQuality {
    /// 低音频质量 audio sample rate: 16KHz audio bitrate: numberOfChannels 1 : 32Kbps  2 : 64Kbps
    case low
    /// 中音频质量 audio sample rate: 44.1KHz audio bitrate: 96Kbps
    case medium
    /// 高音频质量 audio sample rate: 44.1MHz audio bitrate: 128Kbps
    case high
    /// 超高音频质量 audio sample rate: 48KHz, audio bitrate: 128Kbps
    case veryHigh
}

public struct LiveAudioConfiguration {
    /// 声道数目
    let numberOfChannels: UInt32
    /// 采样率
    let audioSampleRate: LiveAudioSampleRate
    /// 码率
    let audioBitRate: LiveAudioBitRate
    /// 缓存区长度
    var bufferLength: Int {
        1024 * 2 * Int(self.numberOfChannels)
    }
}
