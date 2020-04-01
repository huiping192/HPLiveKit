//
//  LiveVideoConfiguration.swift
//  HPLiveKit
//
//  Created by Huiping Guo on 2018/08/20.
//  Copyright © 2018 Huiping Guo. All rights reserved.
//

import Foundation
import AVFoundation

public enum LiveVideoSessionPreset {
    /// 低分辨率
    case preset360x640
    /// 中分辨率
    case preset540x960
    /// 高分辨率
    case preset720x1280

    var avSessionPreset: AVCaptureSession.Preset {
        switch self {
        case .preset360x640:
            return .vga640x480
        case .preset540x960:
            return .iFrame960x540
        case .preset720x1280:
            return .hd1280x720
        }
    }

    var cameraImageSize: CGSize {
        var size: CGSize
        switch self {
        case .preset360x640:
            size = CGSize(width: 360, height: 640)
        case .preset540x960:
            size = CGSize(width: 540, height: 960)
        case .preset720x1280:
            size = CGSize(width: 720, height: 1280)
        default:
            size = CGSize.zero
        }

        return size
    }
}

/// 视频质量
public enum LiveVideoQuality {
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
}

public struct LiveVideoConfiguration {
    // 视频的分辨率，宽高务必设定为 2 的倍数，否则解码播放时可能出现绿边(这个videoSizeRespectingAspectRatio设置为YES则可能会改变)
    let videoSize: CGSize

    // 输出图像是否等比例,默认为false
    var videoSizeRespectingAspectRatio: Bool = false

    // 视频输出方向
    var outputImageOrientation: UIInterfaceOrientation = .portrait

    // 自动旋转(这里只支持 left 变 right  portrait 变 portraitUpsideDown)
    var autorotate: Bool = true

    // 视频的帧率，即 fps
    let videoFrameRate: UInt

    // 视频的最大帧率，即 fps
    let videoMinFrameRate: UInt
    // 视频的最小帧率，即 fps
    let videoMaxFrameRate: UInt

    // 最大关键帧间隔，可设定为 fps 的2倍，影响一个 gop 的大小
    var videoMaxKeyframeInterval: UInt {
        videoFrameRate * 2
    }

    // 视频的码率，单位是 bps
    let videoBitRate: UInt
    // 视频的最大码率，单位是 bps
    let videoMaxBitRate: UInt

    // 视频的最小码率，单位是 bps
    let videoMinBitRate: UInt

    // 分辨率
    let sessionPreset: LiveVideoSessionPreset

    // 系统用分辨率
    var avSessionPreset: AVCaptureSession.Preset {
        sessionPreset.avSessionPreset
    }
}

extension LiveVideoConfiguration {
    var isLandscape: Bool {
        outputImageOrientation == .landscapeLeft || outputImageOrientation == .landscapeRight
    }

    // for internal use
    var internalVideoSize: CGSize {
        if videoSizeRespectingAspectRatio {
            return aspectRatioVideoSize
        }

        return orientationFormatVideoSize
    }

    var orientationFormatVideoSize: CGSize {
        if !isLandscape {
            return videoSize
        }
        return CGSize(width: videoSize.height, height: videoSize.width)
    }

    var aspectRatioVideoSize: CGSize {
        let size = AVMakeRect(aspectRatio: sessionPreset.cameraImageSize, insideRect: CGRect(x: 0, y: 0, width: orientationFormatVideoSize.width, height: orientationFormatVideoSize.height) )

        var width: Int = Int(ceil(size.width))
        var height: Int = Int(ceil(size.height))

        width = width % 2 == 0 ? width :  width - 1
        height = height % 2 == 0 ? height :  height - 1

        return CGSize(width: width, height: height)
    }

}
