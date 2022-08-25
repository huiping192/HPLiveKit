//
//  LiveVideoConfigurationFactory.swift
//  HPLiveKit
//
//  Created by Huiping Guo on 2020/02/21.
//

import Foundation

public struct LiveVideoConfigurationFactory {
    public static var defaultVideoConfiguration: LiveVideoConfiguration {
        return createLow2()
    }

    public static func createLow1() -> LiveVideoConfiguration {
        return LiveVideoConfiguration(videoSize: CGSize(width: 360, height: 640), videoFrameRate: 15, videoMinFrameRate: 10, videoMaxFrameRate: 15, videoBitRate: 500 * 1000, videoMaxBitRate: 600 * 1000, videoMinBitRate: 400 * 1000, sessionPreset: .preset360x640)
    }

    public static func createLow2() -> LiveVideoConfiguration {
        return LiveVideoConfiguration(videoSize: CGSize(width: 360, height: 640), videoFrameRate: 24, videoMinFrameRate: 12, videoMaxFrameRate: 24, videoBitRate: 600 * 1000, videoMaxBitRate: 720 * 1000, videoMinBitRate: 500 * 1000, sessionPreset: .preset360x640)
    }

    public static func createLow3() -> LiveVideoConfiguration {
        return LiveVideoConfiguration(videoSize: CGSize(width: 360, height: 640), videoFrameRate: 30, videoMinFrameRate: 15, videoMaxFrameRate: 30, videoBitRate: 800 * 1000, videoMaxBitRate: 960 * 1000, videoMinBitRate: 600 * 1000, sessionPreset: .preset360x640)
    }

    public static func createMedium1() -> LiveVideoConfiguration {
        return LiveVideoConfiguration(videoSize: CGSize(width: 540, height: 960), videoFrameRate: 15, videoMinFrameRate: 10, videoMaxFrameRate: 15, videoBitRate: 800 * 1000, videoMaxBitRate: 960 * 1000, videoMinBitRate: 500 * 1000, sessionPreset: .preset540x960)
    }

    public static func createMedium2() -> LiveVideoConfiguration {
        return LiveVideoConfiguration(videoSize: CGSize(width: 540, height: 960), videoFrameRate: 24, videoMinFrameRate: 12, videoMaxFrameRate: 24, videoBitRate: 800 * 1000, videoMaxBitRate: 960 * 1000, videoMinBitRate: 500 * 1000, sessionPreset: .preset540x960)
    }

    public static func createMedium3() -> LiveVideoConfiguration {
        return LiveVideoConfiguration(videoSize: CGSize(width: 540, height: 960), videoFrameRate: 30, videoMinFrameRate: 15, videoMaxFrameRate: 30, videoBitRate: 1000 * 1000, videoMaxBitRate: 1200 * 1000, videoMinBitRate: 500 * 1000, sessionPreset: .preset540x960)
    }

    public static func createHigh1() -> LiveVideoConfiguration {
        return LiveVideoConfiguration(videoSize: CGSize(width: 720, height: 1280), videoFrameRate: 15, videoMinFrameRate: 10, videoMaxFrameRate: 15, videoBitRate: 1000 * 1000, videoMaxBitRate: 1200 * 1000, videoMinBitRate: 500 * 1000, sessionPreset: .preset720x1280)
    }

    public static func createHigh2() -> LiveVideoConfiguration {
        return LiveVideoConfiguration(videoSize: CGSize(width: 720, height: 1280), videoFrameRate: 24, videoMinFrameRate: 12, videoMaxFrameRate: 24, videoBitRate: 1200 * 1000, videoMaxBitRate: 1440 * 1000, videoMinBitRate: 800 * 1000, sessionPreset: .preset720x1280)
    }

    public static func createHigh3() -> LiveVideoConfiguration {
        return LiveVideoConfiguration(videoSize: CGSize(width: 720, height: 1280), videoFrameRate: 30, videoMinFrameRate: 15, videoMaxFrameRate: 30, videoBitRate: 1200 * 1000, videoMaxBitRate: 1440 * 1000, videoMinBitRate: 500 * 1000, sessionPreset: .preset720x1280)
    }
}
