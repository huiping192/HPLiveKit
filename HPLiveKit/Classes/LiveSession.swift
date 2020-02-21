//
//  LiveSession.swift
//  HPLiveKit
//
//  Created by Huiping Guo on 2018/08/20.
//  Copyright © 2018 Huiping Guo. All rights reserved.
//

import Foundation
import UIKit

public class LiveSession {
    
    fileprivate let audioConfiguration: LiveAudioConfiguration
    fileprivate let videoConfiguration: LiveVideoConfiguration
    
    
    fileprivate var videoCapture: LiveVideoCapture?
    
    public var perview: UIView? {
        get {
            return videoCapture?.perview
        }
        set {
            videoCapture?.perview = perview
        }
    }
    
    var streamInfo :LiveStreamInfo?
    
    public init(audioConfiguration: LiveAudioConfiguration, videoConfiguration: LiveVideoConfiguration) {
        self.audioConfiguration = audioConfiguration
        self.videoConfiguration = videoConfiguration
        
        videoCapture = LiveVideoCapture(videoConfiguration: videoConfiguration)
    }
    
    
    public func startLive() {
        videoCapture?.setRunning(running: true)
    }
    
    public func stopLive() {
        videoCapture?.setRunning(running: false)
    }
}
