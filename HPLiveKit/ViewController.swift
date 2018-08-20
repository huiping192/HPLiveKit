//
//  ViewController.swift
//  HPLiveKit
//
//  Created by Huiping Guo on 2018/08/20.
//  Copyright © 2018 Huiping Guo. All rights reserved.
//

import UIKit

class ViewController: UIViewController {
    
    private var liveSession: LiveSession?

    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view, typically from a nib.
        
        liveSession = LiveSession(audioConfiguration: .default, videoConfiguration: .default)
        
        liveSession?.perview = view
        
        liveSession?.startLive()
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }
    


}

