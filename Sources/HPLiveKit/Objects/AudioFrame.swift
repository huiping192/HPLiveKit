//
//  AudioFrame.swift
//  HPLiveKit
//
//  Created by Huiping Guo on 2020/02/21.
//

import Foundation

public class AudioFrame: Frame {
    /// flv打包中aac的header
    public var audioInfo: Data?
  
  public var aacHeader: Data?
}
