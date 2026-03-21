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
class TimestampSynchronizer {

    // Unified base timestamp for audio/video synchronization
    // Set to the timestamp of the first frame (audio or video) that arrives
    private var baseTimestamp: UInt64?

    /// Record base timestamp from sample buffer if not yet set
    /// Call this BEFORE encoding to ensure correct timestamp order
    /// - Parameter sampleBuffer: The sample buffer to extract timestamp from
    func recordIfNeeded(_ sampleBuffer: CMSampleBuffer) {
        if baseTimestamp == nil {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            baseTimestamp = UInt64(CMTimeGetSeconds(pts) * 1000)
        }
    }

    /// Normalize audio frame timestamp relative to base timestamp
    /// Call this AFTER encoding to get normalized frame
    /// - Parameter frame: Original audio frame with absolute timestamp
    /// - Returns: New audio frame with normalized timestamp (relative to base)
    func normalize(_ frame: AudioFrame) -> AudioFrame {
        guard let base = baseTimestamp else {
            // If baseTimestamp is not set, return original frame
            // This should not happen in normal flow
            return frame
        }

        // Prevent UInt64 underflow crash
        let normalizedTimestamp = frame.timestamp >= base
            ? frame.timestamp - base
            : 0

        return AudioFrame(
            timestamp: normalizedTimestamp,
            data: frame.data,
            header: frame.header,
            aacHeader: frame.aacHeader
        )
    }

    /// Normalize video frame timestamp relative to base timestamp
    /// Call this AFTER encoding to get normalized frame
    /// - Parameter frame: Original video frame with absolute timestamp
    /// - Returns: New video frame with normalized timestamp (relative to base)
    func normalize(_ frame: VideoFrame) -> VideoFrame {
        guard let base = baseTimestamp else {
            // If baseTimestamp is not set, return original frame
            // This should not happen in normal flow
            return frame
        }

        // Prevent UInt64 underflow crash
        let normalizedTimestamp = frame.timestamp >= base
            ? frame.timestamp - base
            : 0

        return VideoFrame(
            timestamp: normalizedTimestamp,
            data: frame.data,
            header: frame.header,
            isKeyFrame: frame.isKeyFrame,
            compositionTime: frame.compositionTime,
            sps: frame.sps,
            pps: frame.pps
        )
    }

    /// Reset base timestamp (call when starting a new stream)
    func reset() {
        baseTimestamp = nil
    }
}
