//
//  PublisherManagerTests.swift
//  HPLiveKitTests
//

import XCTest
@testable import HPLiveKit

// MARK: - Mock Publisher

actor MockPublisher: Publisher {
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private(set) var receivedFrames: [any Frame] = []
    private weak var delegate: PublisherDelegate?

    func setDelegate(delegate: PublisherDelegate?) async {
        self.delegate = delegate
    }

    func start() async {
        startCallCount += 1
    }

    func stop() async {
        stopCallCount += 1
    }

    func send(frame: any Frame) async {
        receivedFrames.append(frame)
    }

    // Simulate state change notification to the manager via delegate
    func simulateStateChange(_ state: LiveState) {
        delegate?.publisher(publisher: self, publishStatus: state)
    }

    func simulateBufferStatus(_ status: BufferState) {
        delegate?.publisher(publisher: self, bufferStatus: status)
    }

    func simulateError(_ code: LiveSocketErrorCode) {
        delegate?.publisher(publisher: self, errorCode: code)
    }
}

// MARK: - Mock Delegate

final class MockPublisherManagerDelegate: PublisherManagerDelegate, @unchecked Sendable {
    var aggregatedBufferStatuses: [BufferState] = []
    var stateChanges: [(url: String, state: LiveState)] = []
    var errors: [(url: String, code: LiveSocketErrorCode)] = []
    var debugInfos: [(url: String, info: LiveDebug)] = []

    func publisherManager(_ manager: PublisherManager, aggregatedBufferStatus: BufferState) {
        aggregatedBufferStatuses.append(aggregatedBufferStatus)
    }

    func publisherManager(_ manager: PublisherManager, url: String, stateDidChange state: LiveState) {
        stateChanges.append((url: url, state: state))
    }

    func publisherManager(_ manager: PublisherManager, url: String, errorCode: LiveSocketErrorCode) {
        errors.append((url: url, code: errorCode))
    }

    func publisherManager(_ manager: PublisherManager, url: String, debugInfo: LiveDebug) {
        debugInfos.append((url: url, info: debugInfo))
    }
}

// MARK: - Minimal Frame for testing

struct TestFrame: Frame {
    var timestamp: UInt64
    var data: Data?
    var header: Data?
}

// MARK: - Tests

final class PublisherManagerTests: XCTestCase {

    // MARK: - isEmpty

    func testEmptyOnInit() async {
        let manager = PublisherManager()
        let empty = await manager.isEmpty
        XCTAssertTrue(empty)
    }

    func testNotEmptyAfterAdd() async {
        let manager = PublisherManager()
        let publisher = MockPublisher()
        let info = LiveStreamInfo(url: "rtmp://example.com/live/stream1")
        await manager.add(publisher: publisher, for: info)
        let empty = await manager.isEmpty
        XCTAssertFalse(empty)
    }

    func testEmptyAfterRemoveAll() async {
        let manager = PublisherManager()
        let publisher = MockPublisher()
        let info = LiveStreamInfo(url: "rtmp://example.com/live/stream1")
        await manager.add(publisher: publisher, for: info)
        await manager.removeAll()
        let empty = await manager.isEmpty
        XCTAssertTrue(empty)
    }

    // MARK: - startAll / stopAll

    func testStartAllCallsStartOnEachPublisher() async {
        let manager = PublisherManager()
        let pub1 = MockPublisher()
        let pub2 = MockPublisher()
        await manager.add(publisher: pub1, for: LiveStreamInfo(url: "rtmp://a.com/1"))
        await manager.add(publisher: pub2, for: LiveStreamInfo(url: "rtmp://b.com/2"))

        await manager.startAll()

        let count1 = await pub1.startCallCount
        let count2 = await pub2.startCallCount
        XCTAssertEqual(count1, 1)
        XCTAssertEqual(count2, 1)
    }

    func testStopAllCallsStopOnEachPublisher() async {
        let manager = PublisherManager()
        let pub1 = MockPublisher()
        let pub2 = MockPublisher()
        await manager.add(publisher: pub1, for: LiveStreamInfo(url: "rtmp://a.com/1"))
        await manager.add(publisher: pub2, for: LiveStreamInfo(url: "rtmp://b.com/2"))

        await manager.stopAll()

        let count1 = await pub1.stopCallCount
        let count2 = await pub2.stopCallCount
        XCTAssertEqual(count1, 1)
        XCTAssertEqual(count2, 1)
    }

    // MARK: - Frame fan-out

    func testSendFrameFanOutToAllPublishers() async {
        let manager = PublisherManager()
        let pub1 = MockPublisher()
        let pub2 = MockPublisher()
        let pub3 = MockPublisher()
        await manager.add(publisher: pub1, for: LiveStreamInfo(url: "rtmp://a.com/1"))
        await manager.add(publisher: pub2, for: LiveStreamInfo(url: "rtmp://b.com/2"))
        await manager.add(publisher: pub3, for: LiveStreamInfo(url: "rtmp://c.com/3"))

        let frame = TestFrame(timestamp: 1000, data: Data([0x01, 0x02]))
        await manager.send(frame: frame)

        let frames1 = await pub1.receivedFrames
        let frames2 = await pub2.receivedFrames
        let frames3 = await pub3.receivedFrames
        XCTAssertEqual(frames1.count, 1)
        XCTAssertEqual(frames2.count, 1)
        XCTAssertEqual(frames3.count, 1)
    }

    // MARK: - aggregatedState

    func testAggregatedStateEmptyIsReady() async {
        let manager = PublisherManager()
        let state = await manager.aggregatedState
        XCTAssertEqual(state, .ready)
    }

    func testAggregatedStateAnyStartWins() async {
        let manager = PublisherManager()
        let delegate = MockPublisherManagerDelegate()
        await manager.setDelegate(delegate)

        let pub1 = MockPublisher()
        let pub2 = MockPublisher()
        await manager.add(publisher: pub1, for: LiveStreamInfo(url: "rtmp://a.com/1"))
        await manager.add(publisher: pub2, for: LiveStreamInfo(url: "rtmp://b.com/2"))

        // Trigger state changes via delegate bridge
        await manager.handleStateChange(from: "rtmp://a.com/1", state: .start)
        await manager.handleStateChange(from: "rtmp://b.com/2", state: .stop)

        let state = await manager.aggregatedState
        XCTAssertEqual(state, .start)
    }

    func testAggregatedStateAllStopIsStop() async {
        let manager = PublisherManager()
        let pub1 = MockPublisher()
        let pub2 = MockPublisher()
        await manager.add(publisher: pub1, for: LiveStreamInfo(url: "rtmp://a.com/1"))
        await manager.add(publisher: pub2, for: LiveStreamInfo(url: "rtmp://b.com/2"))

        await manager.handleStateChange(from: "rtmp://a.com/1", state: .stop)
        await manager.handleStateChange(from: "rtmp://b.com/2", state: .stop)

        let state = await manager.aggregatedState
        XCTAssertEqual(state, .stop)
    }

    func testAggregatedStateAllErrorIsError() async {
        let manager = PublisherManager()
        let pub1 = MockPublisher()
        let pub2 = MockPublisher()
        await manager.add(publisher: pub1, for: LiveStreamInfo(url: "rtmp://a.com/1"))
        await manager.add(publisher: pub2, for: LiveStreamInfo(url: "rtmp://b.com/2"))

        await manager.handleStateChange(from: "rtmp://a.com/1", state: .error)
        await manager.handleStateChange(from: "rtmp://b.com/2", state: .error)

        let state = await manager.aggregatedState
        XCTAssertEqual(state, .error)
    }

    func testAggregatedStateMixedErrorAndStopIsNotError() async {
        let manager = PublisherManager()
        let pub1 = MockPublisher()
        let pub2 = MockPublisher()
        await manager.add(publisher: pub1, for: LiveStreamInfo(url: "rtmp://a.com/1"))
        await manager.add(publisher: pub2, for: LiveStreamInfo(url: "rtmp://b.com/2"))

        await manager.handleStateChange(from: "rtmp://a.com/1", state: .error)
        await manager.handleStateChange(from: "rtmp://b.com/2", state: .stop)

        let state = await manager.aggregatedState
        // Not all error, not all stop → falls through to first state
        XCTAssertNotEqual(state, .start)
    }

    // MARK: - Buffer status aggregation (most conservative signal wins)

    func testBufferStatusAnyIncreaseDominates() async {
        let manager = PublisherManager()
        let delegate = MockPublisherManagerDelegate()
        await manager.setDelegate(delegate)

        let pub1 = MockPublisher()
        let pub2 = MockPublisher()
        await manager.add(publisher: pub1, for: LiveStreamInfo(url: "rtmp://a.com/1"))
        await manager.add(publisher: pub2, for: LiveStreamInfo(url: "rtmp://b.com/2"))

        await manager.handleBufferStatus(from: "rtmp://a.com/1", status: .increase)
        await manager.handleBufferStatus(from: "rtmp://b.com/2", status: .decline)

        XCTAssertEqual(delegate.aggregatedBufferStatuses.last, .increase)
    }

    func testBufferStatusAllDeclineTriggerDecline() async {
        let manager = PublisherManager()
        let delegate = MockPublisherManagerDelegate()
        await manager.setDelegate(delegate)

        let pub1 = MockPublisher()
        let pub2 = MockPublisher()
        await manager.add(publisher: pub1, for: LiveStreamInfo(url: "rtmp://a.com/1"))
        await manager.add(publisher: pub2, for: LiveStreamInfo(url: "rtmp://b.com/2"))

        await manager.handleBufferStatus(from: "rtmp://a.com/1", status: .decline)
        await manager.handleBufferStatus(from: "rtmp://b.com/2", status: .decline)

        XCTAssertEqual(delegate.aggregatedBufferStatuses.last, .decline)
    }

    func testBufferStatusPartialDeclineNoCallback() async {
        let manager = PublisherManager()
        let delegate = MockPublisherManagerDelegate()
        await manager.setDelegate(delegate)

        let pub1 = MockPublisher()
        let pub2 = MockPublisher()
        await manager.add(publisher: pub1, for: LiveStreamInfo(url: "rtmp://a.com/1"))
        await manager.add(publisher: pub2, for: LiveStreamInfo(url: "rtmp://b.com/2"))

        // Only one of two publishers reports decline — not all decline, no increase → no callback
        await manager.handleBufferStatus(from: "rtmp://a.com/1", status: .decline)

        XCTAssertTrue(delegate.aggregatedBufferStatuses.isEmpty)
    }

    // MARK: - Delegate callbacks

    func testDelegateCalledWithCorrectUrlOnStateChange() async {
        let manager = PublisherManager()
        let delegate = MockPublisherManagerDelegate()
        await manager.setDelegate(delegate)

        let pub = MockPublisher()
        let url = "rtmp://example.com/live/test"
        await manager.add(publisher: pub, for: LiveStreamInfo(url: url))

        await manager.handleStateChange(from: url, state: .start)

        XCTAssertEqual(delegate.stateChanges.count, 1)
        XCTAssertEqual(delegate.stateChanges.first?.url, url)
        XCTAssertEqual(delegate.stateChanges.first?.state, .start)
    }

    func testDelegateCalledWithCorrectUrlOnError() async {
        let manager = PublisherManager()
        let delegate = MockPublisherManagerDelegate()
        await manager.setDelegate(delegate)

        let pub = MockPublisher()
        let url = "rtmp://example.com/live/test"
        await manager.add(publisher: pub, for: LiveStreamInfo(url: url))

        await manager.handleError(from: url, error: .reconnectTimeOut)

        XCTAssertEqual(delegate.errors.count, 1)
        XCTAssertEqual(delegate.errors.first?.url, url)
        XCTAssertEqual(delegate.errors.first?.code, .reconnectTimeOut)
    }

    func testMultiplePublishersIndependentStateTracking() async {
        let manager = PublisherManager()
        let delegate = MockPublisherManagerDelegate()
        await manager.setDelegate(delegate)

        let url1 = "rtmp://youtube.com/live/key"
        let url2 = "rtmp://twitch.tv/live/key"
        let pub1 = MockPublisher()
        let pub2 = MockPublisher()
        await manager.add(publisher: pub1, for: LiveStreamInfo(url: url1))
        await manager.add(publisher: pub2, for: LiveStreamInfo(url: url2))

        await manager.handleStateChange(from: url1, state: .start)
        await manager.handleStateChange(from: url2, state: .error)

        // pub1 started → aggregated = .start
        let state = await manager.aggregatedState
        XCTAssertEqual(state, .start)

        // Two separate delegate calls, one per url
        XCTAssertEqual(delegate.stateChanges.count, 2)
        let urls = delegate.stateChanges.map { $0.url }
        XCTAssertTrue(urls.contains(url1))
        XCTAssertTrue(urls.contains(url2))
    }
}
