//
//  ViewController.swift
//  HPLiveKit
//
//  Created by huiping_guo on 02/21/2020.
//  Copyright (c) 2020 huiping_guo. All rights reserved.
//

import UIKit
import HPLiveKit

class ViewController: UIViewController {

    private var liveSession: LiveSession?

    override func viewDidLoad() {
        super.viewDidLoad()

       configureLiveSession()
    }

    func configureLiveSession() {
        let defaultVidoeConfiguration = LiveVideoConfigurationFactory.defaultVideoConfiguration
        let defaultAudioConfiguration = LiveAudioConfigurationFactory.defaultAudioConfiguration

        let liveSession = LiveSession(audioConfiguration: defaultAudioConfiguration, videoConfiguration: defaultVidoeConfiguration)

        liveSession.perview = view

        liveSession.startLive()
        
        self.liveSession = liveSession
    }
}
