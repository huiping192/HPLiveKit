//
//  LiveVideoConfiguration.swift
//  HPLiveKit
//
//  Created by Huiping Guo on 2018/08/20.
//  Copyright © 2018 Huiping Guo. All rights reserved.
//

import Foundation
import UIKit
import AVFoundation

enum LiveVideoSessionPreset {
    /// 低分辨率
    case preset360x640
    /// 中分辨率
    case preset540x960
    /// 高分辨率
    case preset720x1280
    
    var avSessionPreset: String {
        switch self {
        case .preset360x640:
            return AVCaptureSession.Preset.vga640x480.rawValue
        case .preset540x960:
            return AVCaptureSession.Preset.iFrame960x540.rawValue
        case .preset720x1280:
            return AVCaptureSession.Preset.hd1280x720.rawValue
        }
    }
}

/// 视频质量
enum LiveVideoQuality {
    /// 分辨率： 360 *640 帧数：15 码率：500Kps
    case low1
    /// 分辨率： 360 *640 帧数：24 码率：800Kps
    case low2
    /// 分辨率： 360 *640 帧数：30 码率：800Kps
    case low3
    /// 分辨率： 540 *960 帧数：15 码率：800Kps
    case medium1
    /// 分辨率： 540 *960 帧数：24 码率：800Kps
    case medium2
    /// 分辨率： 540 *960 帧数：30 码率：800Kps
    case medium3
    /// 分辨率： 720 *1280 帧数：15 码率：1000Kps
    case high1
    /// 分辨率： 720 *1280 帧数：24 码率：1200Kps
    case high2
    /// 分辨率： 720 *1280 帧数：30 码率：1200Kps
    case high3
    /// 默认配置
    static let `default`: LiveVideoQuality = .low2
}

struct LiveVideoConfiguration {
    
    let outputImageOrientation: UIInterfaceOrientation
//    let autorotate: Bool
    
    let videoFrameRate: UInt
    
//    let videoMinFrameRate: UInt
//    let videoMaxFrameRate: UInt
//
//
//    let videoMaxKeyframeInterval: UInt
    
    let videoBitRate: UInt
//    let videoMaxBitRate: UInt
//    let videoMinBitRate: Int
    
    let sessionPreset: LiveVideoSessionPreset
    
    static var `default`: LiveVideoConfiguration {
        return LiveVideoConfiguration(outputImageOrientation: .portrait, videoFrameRate: 30, videoBitRate: 80000, sessionPreset: .preset720x1280)
    }
}
