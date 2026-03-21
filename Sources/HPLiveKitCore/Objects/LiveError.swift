//
//  LiveError.swift
//  HPLiveKit
//
//  Created by Huiping Guo on 2025/01/15.
//

import Foundation

/// Unified error types for HPLiveKit
public enum LiveError: Error, LocalizedError, Sendable {
  // MARK: - Video Encoding Errors

  /// Failed to create video compression session
  case videoCompressionSessionCreationFailed(OSStatus)

  /// Failed to encode video frame
  case videoEncodingFailed(OSStatus)

  /// Failed to extract H.264 parameter set (SPS/PPS)
  case videoParameterSetExtractionFailed(OSStatus)

  // MARK: - Audio Encoding Errors

  /// Failed to create audio converter
  case audioConverterCreationFailed(OSStatus)

  /// Failed to encode audio frame
  case audioEncodingFailed(OSStatus)

  /// Audio format description is missing
  case audioFormatDescriptionMissing

  // MARK: - Socket Errors

  /// Socket-related errors (maintains compatibility with LiveSocketErrorCode)
  case socketError(LiveSocketErrorCode)

  // MARK: - LocalizedError

  public var errorDescription: String? {
    switch self {
    case .videoCompressionSessionCreationFailed(let status):
      return "Video compression session creation failed with status: \(status)"

    case .videoEncodingFailed(let status):
      return "Video encoding failed with status: \(status)"

    case .videoParameterSetExtractionFailed(let status):
      return "Failed to extract H.264 parameter set with status: \(status)"

    case .audioConverterCreationFailed(let status):
      return "Audio converter creation failed with status: \(status)"

    case .audioEncodingFailed(let status):
      return "Audio encoding failed with status: \(status)"

    case .audioFormatDescriptionMissing:
      return "Audio format description is missing"

    case .socketError(let code):
      return "Socket error: \(code)"
    }
  }
}
