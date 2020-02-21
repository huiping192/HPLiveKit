//
//  LiveStreamInfo.swift
//  HPLiveKit
//
//  Created by Huiping Guo on 2018/08/20.
//  Copyright © 2018 Huiping Guo. All rights reserved.
//

import Foundation

// 流状态
public enum LiveState: Int {
    /// 准备
    case ready = 0
    /// 连接中
    case pending = 1
    /// 已连接
    case start = 2
    /// 已断开
    case stop = 3
    /// 连接出错
    case error = 4
    ///  正在刷新
    case refresh = 5
}

public enum LiveSocketErrorCode: Int {
    ///< 预览失败
    case previewFail = 201
    ///< 获取流媒体信息失败
    case getStreamInfo = 202
    ///< 连接socket失败
    case connectSocket = 203
    ///< 验证服务器失败
    case verification = 204
    ///< 重新连接服务器超时
    case reconnectTimeOut = 205
}

struct LiveStreamInfo {
    let streamId: String
    
    // --- FLV ---
    let host: String
    let port: Int
    
    // --- rtmp ---
    
    let url: String
    
    ///音频配置
    let audioConfiguration: LiveAudioConfiguration
    ///视频配置
    let videoConfiguration: LiveVideoConfiguration
}
