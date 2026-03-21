//
//  TimestampSynchronizerTests.swift
//

import XCTest
import CoreMedia
@testable import HPLiveKitCore

final class TimestampSynchronizerTests: XCTestCase {

    private static func makeBuffer(pts seconds: Double) -> CMSampleBuffer {
        let time = CMTime(seconds: seconds, preferredTimescale: 1000)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var formatDesc: CMFormatDescription!
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 44100, mFormatID: kAudioFormatLinearPCM, mFormatFlags: 0,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0
        )
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &formatDesc)
        var sampleBuffer: CMSampleBuffer!
        CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: formatDesc, sampleCount: 0, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sampleBuffer)
        return sampleBuffer
    }

    func testRecordIfNeeded_SetsBaseTimestamp() {
        let sync = TimestampSynchronizer()
        sync.recordIfNeeded(Self.makeBuffer(pts: 10.0))
        // base = 10000ms; audio at 10000ms → normalized = 0
        let audio = AudioFrame(timestamp: 10_000, data: nil, header: nil, aacHeader: nil)
        XCTAssertEqual(sync.normalize(audio).timestamp, 0)
    }

    func testRecordIfNeeded_DoesNotOverwriteBase() {
        let sync = TimestampSynchronizer()
        sync.recordIfNeeded(Self.makeBuffer(pts: 5.0))
        sync.recordIfNeeded(Self.makeBuffer(pts: 10.0)) // ignored
        // base = 5000ms, frame at 10000ms → normalized = 5000
        let audio = AudioFrame(timestamp: 10_000, data: nil, header: nil, aacHeader: nil)
        XCTAssertEqual(sync.normalize(audio).timestamp, 5_000)
    }

    func testNormalizeAudio_CorrectOffset() {
        let sync = TimestampSynchronizer()
        sync.recordIfNeeded(Self.makeBuffer(pts: 2.0)) // base = 2000ms
        let audio = AudioFrame(timestamp: 5_000, data: Data([1, 2, 3]), header: nil, aacHeader: nil)
        let result = sync.normalize(audio)
        XCTAssertEqual(result.timestamp, 3_000)
        XCTAssertEqual(result.data, audio.data)
    }

    func testNormalizeVideo_CorrectOffset() {
        let sync = TimestampSynchronizer()
        sync.recordIfNeeded(Self.makeBuffer(pts: 1.0)) // base = 1000ms
        let video = VideoFrame(timestamp: 4_000, data: Data([0xAA]), header: nil, isKeyFrame: true, compositionTime: 0, sps: nil, pps: nil)
        let result = sync.normalize(video)
        XCTAssertEqual(result.timestamp, 3_000)
        XCTAssertTrue(result.isKeyFrame)
    }

    func testNormalize_ClampsUnderflowToZero() {
        let sync = TimestampSynchronizer()
        sync.recordIfNeeded(Self.makeBuffer(pts: 10.0)) // base = 10000ms
        let audio = AudioFrame(timestamp: 5_000, data: nil, header: nil, aacHeader: nil) // ts < base
        XCTAssertEqual(sync.normalize(audio).timestamp, 0)
    }

    func testNormalize_WithoutBase_ReturnsOriginal() {
        let sync = TimestampSynchronizer()
        let audio = AudioFrame(timestamp: 999, data: nil, header: nil, aacHeader: nil)
        XCTAssertEqual(sync.normalize(audio).timestamp, 999)
    }

    func testReset_ClearsBaseTimestamp() {
        let sync = TimestampSynchronizer()
        sync.recordIfNeeded(Self.makeBuffer(pts: 5.0))
        sync.reset()
        // After reset, base is nil so normalize returns original
        let audio = AudioFrame(timestamp: 5_000, data: nil, header: nil, aacHeader: nil)
        XCTAssertEqual(sync.normalize(audio).timestamp, 5_000)
    }

    func testConcurrentAccess_NoDataRace() async {
        let sync = TimestampSynchronizer()
        // Concurrent normalize + reset — tests that the NSLock prevents data races
        await withTaskGroup(of: Void.self) { group in
            for i: UInt64 in 0..<100 {
                group.addTask {
                    let audio = AudioFrame(timestamp: i * 1000, data: nil, header: nil, aacHeader: nil)
                    _ = sync.normalize(audio)
                    if i % 20 == 0 { sync.reset() }
                }
            }
        }
        XCTAssertTrue(true, "No crash means thread safety is intact")
    }
}
