//
//  ViewController.swift
//  HPLiveKit
//
//  Created by huiping_guo on 02/21/2020.
//  Copyright (c) 2020 huiping_guo. All rights reserved.
//

import UIKit
import HPLiveKit
import HPLibRTMP

class ViewController: UIViewController {

    private var liveSession: LiveSession?

    override func viewDidLoad() {
        super.viewDidLoad()

       configureLiveSession()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        let info = LiveStreamInfo(streamId: "sample1", url: "")

        liveSession?.startLive(streamInfo: info)
    }

    func configureLiveSession() {
        let defaultVidoeConfiguration = LiveVideoConfigurationFactory.defaultVideoConfiguration
        let defaultAudioConfiguration = LiveAudioConfigurationFactory.defaultAudioConfiguration

        let liveSession = LiveSession(audioConfiguration: defaultAudioConfiguration, videoConfiguration: defaultVidoeConfiguration)

        liveSession.perview = view
//        liveSession.warterMarkView = UIView()
                
        self.liveSession = liveSession
    }
}

extension ViewController: LiveSessionDelegate {
    func liveSession(session: LiveSession, liveStateDidChange state: LiveState) {
        
    }
    func liveSession(session: LiveSession, debugInfo: LiveDebug) {
        
    }
    func liveSession(session: LiveSession, errorCode: LiveSocketErrorCode) {
        
    }
}
