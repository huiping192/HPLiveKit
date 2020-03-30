//
//  VideoEncoder.swift
//  FBSnapshotTestCase
//
//  Created by Huiping Guo on 2020/02/24.
//

import Foundation

// 编码器编码后回调
protocol VideoEncoderDelegate: class {
    func videoEncoder(encoder: VideoEncoder, frame: VideoFrame)
}

protocol VideoEncoder: class {

    func encodeVideoData(pixelBuffer: CVPixelBuffer, timeStamp: UInt64)

    var videoBitRate: UInt {
        get
        set
    }

    init(configuration: LiveVideoConfiguration)

    weak var delegate: VideoEncoderDelegate? {
        get
        set
    }

    func stopEncoder()
}
