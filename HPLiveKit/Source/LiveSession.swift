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
    
    
    fileprivate var videoCapture: LiveVideoCapture?
    
    var perview: UIView? {
        get {
            return videoCapture?.perview
        }
        set {
            videoCapture?.perview = perview
        }
    }
    
    var streamInfo :LiveStreamInfo?
    
    init(audioConfiguration: LiveAudioConfiguration, videoConfiguration: LiveVideoConfiguration) {
        self.audioConfiguration = audioConfiguration
        self.videoConfiguration = videoConfiguration
        
        videoCapture = LiveVideoCapture(videoConfiguration: videoConfiguration)
    }
    
    
    func startLive() {
        videoCapture?.setRunning(running: true)
    }
    
    func stopLive() {
        videoCapture?.setRunning(running: false)
    }
}
