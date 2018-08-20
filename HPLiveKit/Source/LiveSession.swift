//
//  LiveSession.swift
//  HPLiveKit
//
//  Created by Huiping Guo on 2018/08/20.
//  Copyright © 2018 Huiping Guo. All rights reserved.
//

import Foundation
import UIKit

class LiveSession {
    
    fileprivate let audioConfiguration: LiveAudioConfiguration
    fileprivate let videoConfiguration: LiveVideoConfiguration
    
    var perview: UIView?
    
    var streamInfo :LiveStreamInfo?
    
    init(audioConfiguration: LiveAudioConfiguration, videoConfiguration: LiveVideoConfiguration) {
        self.audioConfiguration = audioConfiguration
        self.videoConfiguration = videoConfiguration
    }
    
    
    func startLive() {
        
    }
    
    func stopLive() {
        
    }
}
