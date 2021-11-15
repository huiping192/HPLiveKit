//
//  VideoFrame.swift
//  HPLiveKit
//
//  Created by Huiping Guo on 2020/02/21.
//

import Foundation

public class VideoFrame: Frame {
    public var isKeyFrame: Bool = false

    public var sps: Data?
    public var pps: Data?
}
