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

            if let perview = newValue, let previewImageView = previewImageView {
                perview.insertSubview(previewImageView, at: 0)
                previewImageView.frame = CGRect(origin: .zero, size: perview.frame.size)
            }
        }
    }

    var captureDevicePosition: AVCaptureDevice.Position? {
        get {
            return videoCamera?.cameraPosition()
        }
        set {
            guard newValue != videoCamera?.cameraPosition() else {
                return
            }

            videoCamera?.rotateCamera()
            videoCamera?.frameRate = Int32(videoConfiguration.videoFrameRate)

            reloadMirror()
        }
    }

    fileprivate var videoConfiguration: LiveVideoConfiguration

    fileprivate var videoCamera: GPUImageVideoCamera?
    fileprivate var output: (GPUImageOutput & GPUImageInput)?
    fileprivate var previewImageView: GPUImageView?

    // 美颜参数
    var beautyFace: Bool = true {
        didSet {
            reloadFilter()
        }
    }
    var beautyLevel: CGFloat = 0.5 {
        didSet {
            
        }
    }
    var brightLevel: CGFloat = 0.5 {
        didSet {
            
        }
    }

    var zoomScale: CGFloat = 1.0 {
        didSet {
            guard let device = videoCamera?.inputCamera as? AVCaptureDevice else { return }
            try? device.lockForConfiguration()
            device.videoZoomFactor = zoomScale
            try? device.unlockForConfiguration()
        }
    }
    
    fileprivate var mirror: Bool = true

    init(videoConfiguration: LiveVideoConfiguration) {
        self.videoConfiguration = videoConfiguration
        
        configureNotifications()

        self.videoCamera = createVideoCamera()
        self.previewImageView = createGPUImageView()
    }
    
    deinit {
        UIApplication.shared.isIdleTimerDisabled = false
        NotificationCenter.default.removeObserver(self)
        
        videoCamera?.stopCapture()
        
        previewImageView?.removeFromSuperview()
        previewImageView = nil
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

    var running: Bool = false {
        didSet {
            guard running != oldValue else { return }
            if running {
                UIApplication.shared.isIdleTimerDisabled = true

                reloadFilter()

                videoCamera?.startCapture()
            } else {
                UIApplication.shared.isIdleTimerDisabled = false
                videoCamera?.stopCapture()
            }
        }
    }

    var torch: Bool {
        get {
            return videoCamera?.inputCamera?.torchMode == .on
        }
        set {
            guard let session = videoCamera?.captureSession else { return }
            
            session.beginConfiguration()
            
            if videoCamera?.inputCamera.isTorchAvailable ?? false {
               try? videoCamera?.inputCamera.lockForConfiguration()
                try videoCamera?.inputCamera.torchMode = torch ? .on : .off
                try? videoCamera?.inputCamera.unlockForConfiguration()
            }
            
            session.commitConfiguration()
        }
    }

    fileprivate func reloadFilter() {

        videoCamera?.addTarget(previewImageView)

        //output = GPUImageEmptyFilter()

        //        videoCamera?.addTarget(output)
        //
        //        output?.addTarget(previewImageView)
    }

    private func reloadMirror() {
        self.videoCamera?.horizontallyMirrorFrontFacingCamera = mirror && self.captureDevicePosition == .front
    }

    var videoFrameRate: Int32 {
        get {
            return videoCamera?.frameRate ?? 0
        }
        set {
            guard newValue > 0 else { return }
            guard newValue != videoCamera?.frameRate else { return }

            videoCamera?.frameRate = newValue
        }
    }

}

// notification
extension LiveVideoCapture {

    func configureNotifications() {
        NotificationCenter.default.addObserver(self, selector: #selector(handleWillEnterBackground), name: Notification.Name.UIApplicationWillResignActive, object: nil)

        NotificationCenter.default.addObserver(self, selector: #selector(handleWillEnterForeground), name: Notification.Name.UIApplicationWillEnterForeground, object: nil)

        NotificationCenter.default.addObserver(self, selector: #selector(handleStatusBarChanged), name: Notification.Name.UIApplicationWillChangeStatusBarOrientation, object: nil)
    }

    @objc func handleWillEnterBackground() {
        UIApplication.shared.isIdleTimerDisabled = false

        videoCamera?.pauseCapture()

        runSynchronouslyOnVideoProcessingQueue {
            glFinish()
        }
    }

    @objc func handleWillEnterForeground() {
        videoCamera?.resumeCameraCapture()

        UIApplication.shared.isIdleTimerDisabled = true
    }

    @objc func handleStatusBarChanged() {
        guard videoConfiguration.autorotate else { return }

        let statusBarOrientation = UIApplication.shared.statusBarOrientation

        if videoConfiguration.isLandscape {
            if statusBarOrientation == .landscapeLeft {
                videoCamera?.outputImageOrientation = .landscapeRight
            } else if statusBarOrientation == .landscapeRight {
                videoCamera?.outputImageOrientation = .landscapeLeft
            }
        } else {
            if statusBarOrientation == .portrait {
                videoCamera?.outputImageOrientation = .portraitUpsideDown
            } else if statusBarOrientation == .portraitUpsideDown {
                videoCamera?.outputImageOrientation = .portrait
            }
        }

    }
}
