//
//  LiveDebug.swift
//  HPLiveKit
//
//  Created by Huiping Guo on 2020/02/21.
//

import Foundation

public struct LiveDebug {
    ///< 流id
    var streamId: String?
    ///< 流地址
    var uploadUrl: String?
    ///< 上传的分辨率
    var videoSize: CGSize?
    ///< 距离上次统计的时间 单位ms
    var elapsedMilli: CGFloat = 0
    ///< 当前的时间戳，从而计算1s内数据
    var currentTimeStamp: CGFloat = 0
    ///< 总流量
    var allDataSize: CGFloat = 0
    ///< 1s内总带宽
    var bandwidthPerSec: CGFloat = 0
    ///< 上次的带宽
    var currentBandwidth: CGFloat = 0

    ///< 丢掉的帧数
    var dropFrameCount: Int = 0
    ///< 总帧数
    var totalFrameCount: Int = 0

    ///< 1s内音频捕获个数
    var capturedAudioCountPerSec: Int = 0
    ///< 1s内视频捕获个数
    var capturedVideoCountPerSec: Int = 0

    ///< 上次的音频捕获个数
    var currentCapturedAudioCount: Int = 0
    ///< 上次的视频捕获个数
    var currentCapturedVideoCount: Int = 0

    ///< 未发送个数（代表当前缓冲区等待发送的）
    var unsendCount: Int = 0
}

extension LiveDebug: CustomStringConvertible {
    public var description: String {
        return String(format: "丢掉的帧数:%ld 总帧数:%ld 上次的音频捕获个数:%d 上次的视频捕获个数:%d 未发送个数:%ld 总流量:%0.f", dropFrameCount, totalFrameCount, currentCapturedAudioCount, currentCapturedVideoCount, unsendCount, allDataSize)
    }
}
