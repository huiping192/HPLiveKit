//
//  LiveAudioConfiguration.swift
//  HPLiveKit
//
//  Created by Huiping Guo on 2018/08/20.
//  Copyright © 2018 Huiping Guo. All rights reserved.
//

import Foundation

// Audio Bitrate
public enum LiveAudioBitRate: Int, Sendable {
  /// 32Kbps audio bitrate
  case a32Kbps = 32000
  /// 64Kbps audio bitrate
  case a64Kbps = 64000
  /// 96Kbps audio bitrate
  case a96Kbps = 96000
  /// 128Kbps audio bitrate
  case a128Kbps = 128000
}

// Audio Sample Rate
public enum LiveAudioSampleRate: Int, Sendable {
  /// 16KHz sample rate
  case s16000Hz = 16000
  /// 44.1KHz sample rate
  case s44100Hz = 44100
  /// 48KHz sample rate
  case s48000Hz = 48000
  
  var sampleRateIndex: UInt8 {
    var sampleRateIndex: UInt8 = 0
    switch self.rawValue {
    case 96000:
      sampleRateIndex = 0
    case 88200:
      sampleRateIndex = 1
    case 64000:
      sampleRateIndex = 2
    case 48000:
      sampleRateIndex = 3
    case 44100:
      sampleRateIndex = 4
    case 32000:
      sampleRateIndex = 5
    case 24000:
      sampleRateIndex = 6
    case 22050:
      sampleRateIndex = 7
    case 16000:
      sampleRateIndex = 8
    case 12000:
      sampleRateIndex = 9
    case 11025:
      sampleRateIndex = 10
    case 8000:
      sampleRateIndex = 11
    case 7350:
      sampleRateIndex = 12
    default:
      sampleRateIndex = 15
    }
    
    return sampleRateIndex
  }
}

public enum LiveAudioQuality {
  /// Low audio quality: audio sample rate 16KHz, audio bitrate: numberOfChannels 1 : 32Kbps  2 : 64Kbps
  case low
  /// Medium audio quality: audio sample rate 44.1KHz, audio bitrate 96Kbps
  case medium
  /// High audio quality: audio sample rate 44.1MHz, audio bitrate 128Kbps
  case high
  /// Very high audio quality: audio sample rate 48KHz, audio bitrate 128Kbps
  case veryHigh
}

public struct LiveAudioConfiguration: Sendable {
  /// Number of channels
  let numberOfChannels: UInt32
  /// Sample rate
  let audioSampleRate: LiveAudioSampleRate
  /// Bitrate
  let audioBitRate: LiveAudioBitRate

  // Audio mixing configuration (for screenShare mode)
  /// Enable audio mixing (app audio + mic audio)
  let audioMixingEnabled: Bool
  /// App audio volume ratio (0.0 - 1.0)
  let appAudioVolume: Float
  /// Mic audio volume ratio (0.0 - 1.0)
  let micAudioVolume: Float

  /// Initialize audio configuration
  /// - Parameters:
  ///   - numberOfChannels: Number of audio channels
  ///   - audioSampleRate: Sample rate
  ///   - audioBitRate: Bitrate
  ///   - audioMixingEnabled: Enable audio mixing (default: true)
  ///   - appAudioVolume: App audio volume ratio (default: 0.7)
  ///   - micAudioVolume: Mic audio volume ratio (default: 1.0)
  public init(
    numberOfChannels: UInt32,
    audioSampleRate: LiveAudioSampleRate,
    audioBitRate: LiveAudioBitRate,
    audioMixingEnabled: Bool = true,
    appAudioVolume: Float = 0.7,
    micAudioVolume: Float = 1.0
  ) {
    self.numberOfChannels = numberOfChannels
    self.audioSampleRate = audioSampleRate
    self.audioBitRate = audioBitRate
    self.audioMixingEnabled = audioMixingEnabled
    self.appAudioVolume = appAudioVolume
    self.micAudioVolume = micAudioVolume
  }
}
