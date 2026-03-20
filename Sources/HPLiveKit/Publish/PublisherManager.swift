//
//  PublisherManager.swift
//  HPLiveKit
//

import Foundation

protocol PublisherManagerDelegate: AnyObject, Sendable {
    func publisherManager(_ manager: PublisherManager, aggregatedBufferStatus: BufferState)
    func publisherManager(_ manager: PublisherManager, url: String, stateDidChange state: LiveState)
    func publisherManager(_ manager: PublisherManager, url: String, errorCode: LiveSocketErrorCode)
    func publisherManager(_ manager: PublisherManager, url: String, debugInfo: LiveDebug)
}

// Per-publisher delegate bridge carrying URL context.
// Uses nonisolated + Task pattern (same as RtmpPublisher: StreamingBufferDelegate).
final class PublisherDelegateBridge: PublisherDelegate, @unchecked Sendable {
    let url: String
    weak var manager: PublisherManager?

    init(url: String, manager: PublisherManager) {
        self.url = url
        self.manager = manager
    }

    func publisher(publisher: Publisher, bufferStatus: BufferState) {
        Task { await manager?.handleBufferStatus(from: url, status: bufferStatus) }
    }

    func publisher(publisher: Publisher, publishStatus: LiveState) {
        Task { await manager?.handleStateChange(from: url, state: publishStatus) }
    }

    func publisher(publisher: Publisher, errorCode: LiveSocketErrorCode) {
        Task { await manager?.handleError(from: url, error: errorCode) }
    }

    func publisher(publisher: Publisher, debugInfo: LiveDebug) {
        Task { await manager?.handleDebugInfo(from: url, info: debugInfo) }
    }
}

actor PublisherManager {
    private struct PublisherEntry {
        let publisher: any Publisher
        let streamInfo: LiveStreamInfo
        // Strong reference needed because RtmpPublisher holds only weak delegate
        let delegateBridge: PublisherDelegateBridge
        var state: LiveState = .ready
    }

    private var publishers: [String: PublisherEntry] = [:]
    private var publisherBufferStates: [String: BufferState] = [:]
    weak var delegate: (any PublisherManagerDelegate)?

    func setDelegate(_ delegate: (any PublisherManagerDelegate)?) {
        self.delegate = delegate
    }

    func add(streamInfo: LiveStreamInfo) async {
        let publisher = RtmpPublisher(stream: streamInfo)
        await add(publisher: publisher, for: streamInfo)
    }

    // Allows injecting a pre-built publisher; used by unit tests.
    func add(publisher: any Publisher, for streamInfo: LiveStreamInfo) async {
        let url = streamInfo.url
        let bridge = PublisherDelegateBridge(url: url, manager: self)
        await publisher.setDelegate(delegate: bridge)
        publishers[url] = PublisherEntry(publisher: publisher, streamInfo: streamInfo, delegateBridge: bridge)
    }

    func removeAll() async {
        publishers.removeAll()
        publisherBufferStates.removeAll()
    }

    func startAll() async {
        await withTaskGroup(of: Void.self) { group in
            for entry in publishers.values {
                group.addTask { await entry.publisher.start() }
            }
        }
    }

    func stopAll() async {
        await withTaskGroup(of: Void.self) { group in
            for entry in publishers.values {
                group.addTask { await entry.publisher.stop() }
            }
        }
    }

    func send(frame: any Frame) async {
        await withTaskGroup(of: Void.self) { group in
            for entry in publishers.values {
                group.addTask { await entry.publisher.send(frame: frame) }
            }
        }
    }

    // Any .start -> overall .start; all .error -> overall .error; all .stop -> overall .stop
    var aggregatedState: LiveState {
        let states = publishers.values.map { $0.state }
        if states.isEmpty { return .ready }
        if states.contains(.start) { return .start }
        if states.allSatisfy({ $0 == .error }) { return .error }
        if states.allSatisfy({ $0 == .stop }) { return .stop }
        if states.contains(.pending) { return .pending }
        return states.first ?? .ready
    }

    var isEmpty: Bool { publishers.isEmpty }

    func handleBufferStatus(from url: String, status: BufferState) {
        publisherBufferStates[url] = status
        // Most conservative signal wins: any slow path triggers bitrate decrease
        if publisherBufferStates.values.contains(where: { $0 == .increase }) {
            delegate?.publisherManager(self, aggregatedBufferStatus: .increase)
            return
        }
        // Only increase bitrate when all registered publishers have reported decline
        if publisherBufferStates.count == publishers.count &&
           publisherBufferStates.values.allSatisfy({ $0 == .decline }) {
            delegate?.publisherManager(self, aggregatedBufferStatus: .decline)
        }
    }

    func handleStateChange(from url: String, state: LiveState) {
        if var entry = publishers[url] {
            entry.state = state
            publishers[url] = entry
        }
        delegate?.publisherManager(self, url: url, stateDidChange: state)
    }

    func handleError(from url: String, error: LiveSocketErrorCode) {
        delegate?.publisherManager(self, url: url, errorCode: error)
    }

    func handleDebugInfo(from url: String, info: LiveDebug) {
        delegate?.publisherManager(self, url: url, debugInfo: info)
    }
}
