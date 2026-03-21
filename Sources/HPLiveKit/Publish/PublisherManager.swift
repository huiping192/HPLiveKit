//
//  PublisherManager.swift
//  HPLiveKit
//

import Foundation

protocol PublisherManagerDelegate: AnyObject, Sendable {
    func publisherManager(_ manager: PublisherManager, aggregatedBufferStatus: BufferState)
    func publisherManager(_ manager: PublisherManager, streamInfo: LiveStreamInfo, stateDidChange state: LiveState)
    func publisherManager(_ manager: PublisherManager, streamInfo: LiveStreamInfo, errorCode: LiveSocketErrorCode)
    func publisherManager(_ manager: PublisherManager, streamInfo: LiveStreamInfo, debugInfo: LiveDebug)
}

// Per-publisher delegate bridge carrying stream identity context.
// Uses nonisolated + Task pattern (same as RtmpPublisher: StreamingBufferDelegate).
final class PublisherDelegateBridge: PublisherDelegate, @unchecked Sendable {
    let streamInfo: LiveStreamInfo
    weak var manager: PublisherManager?

    init(streamInfo: LiveStreamInfo, manager: PublisherManager) {
        self.streamInfo = streamInfo
        self.manager = manager
    }

    func publisher(publisher: Publisher, bufferStatus: BufferState) {
        Task { await manager?.handleBufferStatus(from: streamInfo.id, status: bufferStatus) }
    }

    func publisher(publisher: Publisher, publishStatus: LiveState) {
        Task { await manager?.handleStateChange(from: streamInfo.id, state: publishStatus) }
    }

    func publisher(publisher: Publisher, errorCode: LiveSocketErrorCode) {
        Task { await manager?.handleError(from: streamInfo.id, error: errorCode) }
    }

    func publisher(publisher: Publisher, debugInfo: LiveDebug) {
        Task { await manager?.handleDebugInfo(from: streamInfo.id, info: debugInfo) }
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

    private var publishers: [String: PublisherEntry] = [:]          // keyed by id
    private var publisherBufferStates: [String: BufferState] = [:]   // keyed by id
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
        let bridge = PublisherDelegateBridge(streamInfo: streamInfo, manager: self)
        await publisher.setDelegate(delegate: bridge)
        publishers[streamInfo.id] = PublisherEntry(publisher: publisher, streamInfo: streamInfo, delegateBridge: bridge)
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

    func handleBufferStatus(from id: String, status: BufferState) {
        publisherBufferStates[id] = status
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

    func handleStateChange(from id: String, state: LiveState) {
        if var entry = publishers[id] {
            entry.state = state
            publishers[id] = entry
        }
        guard let streamInfo = publishers[id]?.streamInfo else { return }
        delegate?.publisherManager(self, streamInfo: streamInfo, stateDidChange: state)
    }

    func handleError(from id: String, error: LiveSocketErrorCode) {
        guard let streamInfo = publishers[id]?.streamInfo else { return }
        delegate?.publisherManager(self, streamInfo: streamInfo, errorCode: error)
    }

    func handleDebugInfo(from id: String, info: LiveDebug) {
        guard let streamInfo = publishers[id]?.streamInfo else { return }
        delegate?.publisherManager(self, streamInfo: streamInfo, debugInfo: info)
    }
}
