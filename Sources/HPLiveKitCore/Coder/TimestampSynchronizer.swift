//
//  TimestampSynchronizer.swift
//  HPLiveKit
//
//  Created by Claude Code on 2025/10/15.
//

import Foundation
import CoreMedia

/// Synchronizes timestamps across audio and video frames
/// Converts absolute timestamps to relative timestamps starting from 0
/// Thread-safe: recordIfNeeded/normalize/reset may be called from different threads
package final class TimestampSynchronizer: @unchecked Sendable {

    // Unified base timestamp for audio/video synchronization
    // Set to the timestamp of the first frame (audio or video) that arrives
    private var baseTimestamp: UInt64?
    private let lock = NSLock()

    package init() {}

    /// Record base timestamp from sample buffer if not yet set
    package func recordIfNeeded(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }
        if baseTimestamp == nil {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            baseTimestamp = UInt64(CMTimeGetSeconds(pts) * 1000)
        }
    }

    package func normalize(_ frame: AudioFrame) -> AudioFrame {
        lock.lock()
        let base = baseTimestamp
        lock.unlock()

        guard let base else { return frame }
        let ts = frame.timestamp >= base ? frame.timestamp - base : 0
        return AudioFrame(timestamp: ts, data: frame.data, header: frame.header, aacHeader: frame.aacHeader)
    }

    package func normalize(_ frame: VideoFrame) -> VideoFrame {
        lock.lock()
        let base = baseTimestamp
        lock.unlock()

        guard let base else { return frame }
        let ts = frame.timestamp >= base ? frame.timestamp - base : 0
        return VideoFrame(
            timestamp: ts, data: frame.data, header: frame.header,
            isKeyFrame: frame.isKeyFrame, compositionTime: frame.compositionTime,
            sps: frame.sps, pps: frame.pps
        )
    }

    /// Reset base timestamp (call when starting a new stream)
    package func reset() {
        lock.lock()
        defer { lock.unlock() }
        baseTimestamp = nil
    }
}
