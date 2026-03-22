//
//  LiveAudioConfigurationTests.swift
//

import XCTest
@testable import HPLiveKitCore

final class LiveAudioConfigurationTests: XCTestCase {

    // MARK: - sampleRateIndex

    func testSampleRateIndex_16000() {
        XCTAssertEqual(LiveAudioSampleRate.s16000Hz.sampleRateIndex, 8)
    }

    func testSampleRateIndex_44100() {
        XCTAssertEqual(LiveAudioSampleRate.s44100Hz.sampleRateIndex, 4)
    }

    func testSampleRateIndex_48000() {
        XCTAssertEqual(LiveAudioSampleRate.s48000Hz.sampleRateIndex, 3)
    }

    // MARK: - Init stores values correctly

    func testInit_StoresAllFields() {
        let config = LiveAudioConfiguration(
            numberOfChannels: 2,
            audioSampleRate: .s44100Hz,
            audioBitRate: .a128Kbps,
            audioMixingEnabled: true,
            appAudioVolume: 0.8,
            micAudioVolume: 0.9
        )
        XCTAssertEqual(config.numberOfChannels, 2)
        XCTAssertEqual(config.audioSampleRate, .s44100Hz)
        XCTAssertEqual(config.audioBitRate, .a128Kbps)
        XCTAssertTrue(config.audioMixingEnabled)
        XCTAssertEqual(config.appAudioVolume, 0.8, accuracy: 0.001)
        XCTAssertEqual(config.micAudioVolume, 0.9, accuracy: 0.001)
    }

    func testInit_DefaultMixingValues() {
        let config = LiveAudioConfiguration(
            numberOfChannels: 1,
            audioSampleRate: .s48000Hz,
            audioBitRate: .a96Kbps
        )
        XCTAssertTrue(config.audioMixingEnabled)
        XCTAssertEqual(config.appAudioVolume, 0.6, accuracy: 0.001)
        XCTAssertEqual(config.micAudioVolume, 1.0, accuracy: 0.001)
    }

    // MARK: - LiveAudioBitRate raw values

    func testBitRateRawValues() {
        XCTAssertEqual(LiveAudioBitRate.a32Kbps.rawValue, 32000)
        XCTAssertEqual(LiveAudioBitRate.a64Kbps.rawValue, 64000)
        XCTAssertEqual(LiveAudioBitRate.a96Kbps.rawValue, 96000)
        XCTAssertEqual(LiveAudioBitRate.a128Kbps.rawValue, 128000)
    }

    // MARK: - LiveAudioSampleRate raw values

    func testSampleRateRawValues() {
        XCTAssertEqual(LiveAudioSampleRate.s16000Hz.rawValue, 16000)
        XCTAssertEqual(LiveAudioSampleRate.s44100Hz.rawValue, 44100)
        XCTAssertEqual(LiveAudioSampleRate.s48000Hz.rawValue, 48000)
    }
}
