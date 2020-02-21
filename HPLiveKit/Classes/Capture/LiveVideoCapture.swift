//
//  VideoCapture.swift
//  HPLiveKit
//
//  Created by Huiping Guo on 2018/08/20.
//  Copyright © 2018 Huiping Guo. All rights reserved.
//

import Foundation
import GPUImage

class LiveVideoCapture {
    
    public var perview: UIView? {
        get {
            return previewImageView?.superview
        }
        set {
            if previewImageView?.superview != nil {
                previewImageView?.removeFromSuperview()
            }
            
            if let perview = perview, let previewImageView = previewImageView {
                perview.insertSubview(previewImageView, at: 0)
                //TODO: autolayoutに移行
                previewImageView.frame = CGRect(origin: .zero, size: perview.frame.size)
            }
        }
    }

    fileprivate var videoConfiguration: LiveVideoConfiguration
    
    fileprivate var videoCamera: GPUImageVideoCamera?
    fileprivate var output: (GPUImageOutput & GPUImageInput)?
    fileprivate var previewImageView: GPUImageView?
    
    init(videoConfiguration: LiveVideoConfiguration) {
        self.videoConfiguration = videoConfiguration
        
        self.videoCamera = createVideoCamera()
        self.previewImageView = createGPUImageView()
    }
    
    
    fileprivate func createVideoCamera() -> GPUImageVideoCamera? {
        let videoCamera = GPUImageVideoCamera(sessionPreset: videoConfiguration.sessionPreset.avSessionPreset, cameraPosition: .front)
        videoCamera?.outputImageOrientation = videoConfiguration.outputImageOrientation
        videoCamera?.horizontallyMirrorRearFacingCamera = true
        videoCamera?.horizontallyMirrorFrontFacingCamera = true
        videoCamera?.frameRate = Int32(videoConfiguration.videoFrameRate)
        
        return videoCamera
    }
    
    fileprivate func createGPUImageView() -> GPUImageView? {
        let gpuImageView = GPUImageView(frame: UIScreen.main.bounds)
        gpuImageView.fillMode = kGPUImageFillModePreserveAspectRatioAndFill
        gpuImageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        return gpuImageView
    }

    fileprivate var running: Bool = false
    
    func setRunning(running: Bool) {
        if self.running == running {
            return
        }
        self.running = running
        if !self.running {
            UIApplication.shared.isIdleTimerDisabled = false
            videoCamera?.stopCapture()
        } else {
            UIApplication.shared.isIdleTimerDisabled = true
            
            reloadFilter()
            
            videoCamera?.startCapture()
        }
    }
    
    fileprivate func reloadFilter() {
        
        videoCamera?.addTarget(previewImageView)
        
        //output = GPUImageEmptyFilter()
        
//        videoCamera?.addTarget(output)
//
//        output?.addTarget(previewImageView)
    }
    
    
    
    
    
}
