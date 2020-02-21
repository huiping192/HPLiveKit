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

        let defaultVidoeConfiguration = LiveVideoConfigurationFactory.defaultVideoConfiguration

        liveSession = LiveSession(audioConfiguration: .default, videoConfiguration: defaultVidoeConfiguration)

        liveSession!.perview = view

        liveSession!.startLive()
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }

}
