//
//  TimestampNormalizer.swift
//  HPLiveKit
//
//  Created by Claude on 2025/10/12.
//

import Foundation
import CoreMedia

/// Responsible for normalizing CMSampleBuffer timestamps to start from zero
///
/// This class ensures thread-safe timestamp normalization for audio and video sample buffers.
/// The first sample buffer's timestamp is recorded as the base, and all subsequent buffers
/// have their timestamps adjusted relative to this base.
///
/// Note: Uses NSLock instead of Actor because CMSampleBuffer does not conform to Sendable,
/// but is thread-safe through its reference counting mechanism.
public final class TimestampNormalizer: @unchecked Sendable {

    /// Base timestamp recorded from the first sample buffer
    private var baseTimestamp: CMTime?
    private let lock = NSLock()

    public init() {}

    /// Normalize a sample buffer's timestamp to be relative to the first received timestamp
    /// - Parameter sampleBuffer: The sample buffer to normalize
    /// - Returns: A new sample buffer with normalized timestamp, or the original buffer if normalization fails
    public func normalize(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer {
        lock.lock()
        defer { lock.unlock() }

        let originalTimestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        // Record first timestamp as base
        if baseTimestamp == nil {
            baseTimestamp = originalTimestamp
            #if DEBUG
            print("[TimestampNormalizer] Base timestamp set to \(originalTimestamp.seconds)s")
            #endif
        }

        guard let base = baseTimestamp else {
            return sampleBuffer
        }

        // Calculate relative timestamp
        let relativeTimestamp = CMTimeSubtract(originalTimestamp, base)

        // Create new sample buffer with relative timestamp
        var timingInfo = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sampleBuffer),
            presentationTimeStamp: relativeTimestamp,
            decodeTimeStamp: .invalid
        )

        var newSampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleBufferOut: &newSampleBuffer
        )

        if status == noErr, let newBuffer = newSampleBuffer {
            return newBuffer
        } else {
            #if DEBUG
            print("[TimestampNormalizer] Failed to create normalized sample buffer, using original")
            #endif
            return sampleBuffer
        }
    }

    /// Reset the base timestamp (call when starting a new stream)
    public func reset() {
        lock.lock()
        defer { lock.unlock() }

        baseTimestamp = nil
        #if DEBUG
        print("[TimestampNormalizer] Timestamp reset")
        #endif
    }
}
