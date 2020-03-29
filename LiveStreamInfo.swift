//
//  LiveStreamInfo.swift
//  HPLiveKit
//
//  Created by Huiping Guo on 2018/08/20.
//  Copyright © 2018 Huiping Guo. All rights reserved.
//

import Foundation

public struct LiveStreamInfo {
    public let streamId: String

    // --- rtmp ---
    public let url: String

    ///音频配置
    var audioConfiguration: LiveAudioConfiguration?
    ///视频配置
    var videoConfiguration: LiveVideoConfiguration?

    public init(streamId: String, url: String) {
        self.streamId = streamId
        self.url = url
    }
}
