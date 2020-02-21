//
//  LiveDebug.swift
//  HPLiveKit
//
//  Created by Huiping Guo on 2020/02/21.
//

import Foundation

struct LiveDebug {

    ///< 流id
    let streamId: String
    ///< 流地址
    let uploadUrl: String
    ///< 上传的分辨率
    let videoSize: CGSize
    ///< 上传方式（TCP or RTMP）
    let isRtmp: Bool

    ///< 距离上次统计的时间 单位ms
    let elapsedMilli: CGFloat
    ///< 当前的时间戳，从而计算1s内数据
    let timeStamp: CGFloat
    ///< 总流量
    let dataFlow: CGFloat
    ///< 1s内总带宽
    let bandwidth: CGFloat
    ///< 上次的带宽
    let currentBandwidth: CGFloat

    ///< 丢掉的帧数
    let dropFrame: Int
    ///< 总帧数
    let totalFrame: Int

    ///< 1s内音频捕获个数
    let capturedAudioCount: Int
    ///< 1s内视频捕获个数
    let capturedVideoCount: Int

    ///< 上次的音频捕获个数
    let currentCapturedAudioCount: Int
    ///< 上次的视频捕获个数
    let currentCapturedVideoCount: Int

    ///< 未发送个数（代表当前缓冲区等待发送的）
    let unSendCount: Int
}

extension LiveDebug: CustomStringConvertible {
    var description: String {
        return String(format: "丢掉的帧数:%ld 总帧数:%ld 上次的音频捕获个数:%d 上次的视频捕获个数:%d 未发送个数:%ld 总流量:%0.f", dropFrame, totalFrame, currentCapturedAudioCount, currentCapturedVideoCount, unSendCount, dataFlow)
    }
}
