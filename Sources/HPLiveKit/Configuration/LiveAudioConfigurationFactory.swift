//
//  LiveAudioConfigurationFactory.swift
//  HPLiveKit
//
//  Created by Huiping Guo on 2020/02/21.
//

import Foundation

public struct LiveAudioConfigurationFactory {
    public static var defaultAudioConfiguration: LiveAudioConfiguration {
        return createHigh()
    }

    public static func createLow() -> LiveAudioConfiguration {
        return LiveAudioConfiguration(numberOfChannels: 2, audioSampleRate: .s16000Hz, audioBitRate: .a64Kbps)
    }

    public static func createMedium() -> LiveAudioConfiguration {
        return LiveAudioConfiguration(numberOfChannels: 2, audioSampleRate: .s44100Hz, audioBitRate: .a96Kbps)
    }

    public static func createHigh() -> LiveAudioConfiguration {
        return LiveAudioConfiguration(numberOfChannels: 2, audioSampleRate: .s44100Hz, audioBitRate: .a128Kbps)
    }

    public static func createVeryHigh() -> LiveAudioConfiguration {
        return LiveAudioConfiguration(numberOfChannels: 2, audioSampleRate: .s48000Hz, audioBitRate: .a128Kbps)
    }
}
