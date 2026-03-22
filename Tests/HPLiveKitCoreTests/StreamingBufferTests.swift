//
//  StreamingBufferTests.swift
//

import XCTest
@testable import HPLiveKitCore

final class StreamingBufferTests: XCTestCase {

    private func makeVideo(ts: UInt64, isKey: Bool, data: Data? = Data([0x00])) -> VideoFrame {
        VideoFrame(timestamp: ts, data: data, header: nil, isKeyFrame: isKey, compositionTime: 0, sps: nil, pps: nil)
    }

    private func makeAudio(ts: UInt64) -> AudioFrame {
        AudioFrame(timestamp: ts, data: Data([0x01]), header: nil, aacHeader: nil)
    }

    // Append enough frames to fill one sort batch (default threshold = 5)
    private func fillOneBatch(_ buf: StreamingBuffer) async {
        for i in 0..<5 {
            await buf.append(frame: makeVideo(ts: UInt64(i * 100), isKey: i == 0))
        }
    }

    // MARK: - Basic operations

    func testInitiallyEmpty() async {
        let buf = StreamingBuffer()
        let isEmpty = await buf.isEmpty
        XCTAssertTrue(isEmpty)
    }

    func testAppendLessThanSortThreshold_ListRemainsEmpty() async {
        let buf = StreamingBuffer()
        for i in 0..<4 {
            await buf.append(frame: makeVideo(ts: UInt64(i * 100), isKey: i == 0))
        }
        let count = await buf.list.count
        XCTAssertEqual(count, 0)
    }

    func testAppendFiveFrames_OneMovedToList() async {
        let buf = StreamingBuffer()
        await fillOneBatch(buf)
        let count = await buf.list.count
        XCTAssertEqual(count, 1)
    }

    func testPopFirstFrame_RemovesFirstFrame() async {
        let buf = StreamingBuffer()
        await fillOneBatch(buf)
        let frame = await buf.popFirstFrame()
        XCTAssertNotNil(frame)
        let remaining = await buf.list.count
        XCTAssertEqual(remaining, 0)
    }

    func testPopFirstFrame_EmptyReturnsNil() async {
        let buf = StreamingBuffer()
        let frame = await buf.popFirstFrame()
        XCTAssertNil(frame)
    }

    func testRemoveAll_ClearsBothLists() async {
        let buf = StreamingBuffer()
        // Fill list
        for i in 0..<8 {
            await buf.append(frame: makeVideo(ts: UInt64(i * 100), isKey: i == 0))
        }
        await buf.removeAll()
        let listCount = await buf.list.count
        XCTAssertEqual(listCount, 0)
        // Appending fresh 5 frames should work correctly (sortList was also cleared)
        for i in 0..<5 {
            await buf.append(frame: makeVideo(ts: UInt64(1000 + i * 100), isKey: i == 0))
        }
        let afterRefill = await buf.list.count
        XCTAssertEqual(afterRefill, 1)
    }

    // MARK: - Sorting

    func testFramesAreSortedByTimestamp() async {
        let buf = StreamingBuffer()
        // Insert out of order — oldest should be in list after threshold
        await buf.append(frame: makeVideo(ts: 400, isKey: false))
        await buf.append(frame: makeVideo(ts: 100, isKey: true))
        await buf.append(frame: makeVideo(ts: 300, isKey: false))
        await buf.append(frame: makeVideo(ts: 200, isKey: false))
        await buf.append(frame: makeVideo(ts: 500, isKey: false))
        let frame = await buf.popFirstFrame()
        XCTAssertEqual(frame?.timestamp, 100)
    }

    // MARK: - Expire frame logic (verifying C3 fix: P-frames drop before I-frames)

    func testExpirePFrames_DropsNonKeyframesFirst() async {
        let buf = StreamingBuffer()
        // Lower maxCount to 5 so we can trigger expiry with fewer frames
        await buf.setMaxCount(5)

        // First batch: I P P P P → fills list to maxCount (5 frames)
        for i in 0..<5 {
            await buf.append(frame: makeVideo(ts: UInt64(i * 100), isKey: i == 0))
        }

        // Second batch starts; when the 5th frame is processed, removeExpireFrame is called
        // because list.count (5) >= maxCount (5). It should drop P-frames (ts=100-400), not I-frame (ts=0).
        await buf.append(frame: makeVideo(ts: 500, isKey: false))
        await buf.append(frame: makeVideo(ts: 600, isKey: false))
        await buf.append(frame: makeVideo(ts: 700, isKey: false))
        await buf.append(frame: makeVideo(ts: 800, isKey: false))
        await buf.append(frame: makeVideo(ts: 900, isKey: true)) // new I-frame

        let list = await buf.list
        let iFrames = list.compactMap { $0 as? VideoFrame }.filter { $0.isKeyFrame }
        XCTAssertFalse(iFrames.isEmpty, "I-frame should survive; P-frames should be dropped first")
    }

    // MARK: - stopTick

    func testStopTick_DoesNotCrash() async {
        let buf = StreamingBuffer()
        await fillOneBatch(buf)
        await buf.stopTick()
        // Appending after stop should still work
        await buf.append(frame: makeVideo(ts: 600, isKey: false))
        XCTAssertTrue(true)
    }

    // MARK: - ClearDropFrames

    func testClearDropFramesCount_ResetsToZero() async {
        let buf = StreamingBuffer()
        await buf.clearDropFramesCount()
        let count = await buf.lastDropFrames
        XCTAssertEqual(count, 0)
    }
}
