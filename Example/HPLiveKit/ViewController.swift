//
//  ViewController.swift
//  HPLiveKit
//
//  Created by huiping_guo on 02/21/2020.
//  Copyright (c) 2020 huiping_guo. All rights reserved.
//

import UIKit
import HPLiveKit
import HPRTMP
class ViewController: UIViewController {
  
  private var liveSession: LiveSession?
  private var liveState: LiveState = .ready
  
  @IBOutlet private var button: UIButton!
  
  override func viewDidLoad() {
    super.viewDidLoad()
    
    button.setTitle("Publish", for: .normal)
    button.addTarget(self, action: #selector(buttonTapped), for: .touchUpInside)
    
    configureLiveSession()
  }
  
  @objc private func buttonTapped() {
    switch liveState {
    case .ready, .stop, .error:
      let info = LiveStreamInfo(streamId: "sample1", url: "rtmp://192.168.11.48/live/haha")
      liveSession?.startLive(streamInfo: info)
      liveState = .start
      button.setTitle("Stop", for: .normal)
    case .start:
      liveSession?.stopLive()
      liveState = .stop
      button.setTitle("Publish", for: .normal)
    default:
      break
    }
  }
  
  func configureLiveSession() {
    let defaultVideoConfiguration = LiveVideoConfigurationFactory.defaultVideoConfiguration
    let defaultAudioConfiguration = LiveAudioConfigurationFactory.defaultAudioConfiguration
    
    let liveSession = LiveSession(audioConfiguration: defaultAudioConfiguration, videoConfiguration: defaultVideoConfiguration)
    liveSession.delegate = self
    liveSession.preview = view
    liveSession.startCapturing()
    self.liveSession = liveSession
  }
}

extension ViewController: LiveSessionDelegate {
  func liveSession(session: LiveSession, liveStateDidChange state: LiveState) {
    liveState = state
    DispatchQueue.main.async {
      switch state {
      case .ready, .stop, .error:
        self.button.setTitle("Publish", for: .normal)
      case .start:
        self.button.setTitle("Stop", for: .normal)
      default:
        break
      }
    }
  }

  func liveSession(session: LiveSession, debugInfo: LiveDebug) {
  }

  func liveSession(session: LiveSession, errorCode: LiveSocketErrorCode) {
    liveState = .error
    button.setTitle("Publish", for: .normal)
  }
}
