//
//  SampleBufferBox.swift
//  HPLiveKit
//
//  Created by 郭 輝平 on 2025/10/23.
//
import AVFoundation

/// A wrapper for CMSampleBuffer to provide Sendable conformance for Swift 6 concurrency
///
/// CMSampleBuffer is not marked as Sendable by Apple, but it is safe to pass across actor boundaries
/// as long as it's not mutated after creation. This box uses @unchecked Sendable to bridge the gap.
///
/// **Thread Safety Guarantee**:
/// - CMSampleBuffer is immutable after creation (Core Media framework ensures this)
/// - Only read operations are performed across actor boundaries
/// - No concurrent mutations occur in our usage pattern
///
/// **Usage Limitations**:
/// - Do NOT mutate the wrapped CMSampleBuffer after boxing
/// - Do NOT share the same box across multiple concurrent write operations
/// - Treat the wrapped CMSampleBuffer as read-only after it's been boxed
struct SampleBufferBox: @unchecked Sendable {
  let samplebuffer: CMSampleBuffer
}
