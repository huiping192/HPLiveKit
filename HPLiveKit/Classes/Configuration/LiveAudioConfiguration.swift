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
    let numberOfChannels: UInt
    /// 采样率
    let audioSampleRate: LiveAudioSampleRate
    /// 码率
    let audioBitRate: LiveAudioBitRate
    /// flv编码音频头 44100 为0x12 0x10
    // FIXME: 実装
    private(set) var asc: Character?
    /// 缓存区长度
    var bufferLength: UInt {
        return 1024*2*self.numberOfChannels
    }
}
