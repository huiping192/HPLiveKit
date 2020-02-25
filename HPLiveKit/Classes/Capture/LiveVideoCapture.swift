//
//  VideoCapture.swift
//  HPLiveKit
//
//  Created by Huiping Guo on 2018/08/20.
//  Copyright © 2018 Huiping Guo. All rights reserved.
//

import Foundation
import GPUImage

protocol LiveVideoCaptureDelegate: class {
    func captureOutput(capture: LiveVideoCapture, pixelBuffer: CVPixelBuffer?)
}

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

    weak var delegate: LiveVideoCaptureDelegate?

    fileprivate var videoConfiguration: LiveVideoConfiguration

    fileprivate var videoCamera: GPUImageVideoCamera?
    fileprivate var output: (GPUImageOutput & GPUImageInput)?
    fileprivate var previewImageView: GPUImageView?

    var warterMarkView: UIView? {
        didSet {
            guard let warterMarkView = warterMarkView else { return }
            if warterMarkView.superview != nil {
                warterMarkView.removeFromSuperview()
            }

            blendFilter?.mix = warterMarkView.alpha
            waterMarkContentView?.addSubview(warterMarkView)

            reloadFilter()
        }
    }
    /*
     gpuimage filters
     */
    //    private var beautyFilter: LFGPUImageBeautyFilter?
    private var filter: (GPUImageOutput & GPUImageInput)?
    private var cropFilter: GPUImageCropFilter?
    private var blendFilter: GPUImageAlphaBlendFilter?
    private var uiElementInput: GPUImageUIElement?

    private var waterMarkContentView: UIView?

    private var movieWriter: MovieWriter?

    /* The saveLocalVideo is save the local video */
    var saveLocalVideo: Bool = false
    /* The saveLocalVideoPath is save the local video  path */
    var saveLocalVideoPath: URL?

    var currentImage: UIImage? {
        guard let filter = filter else {
            return nil
        }

        filter.useNextFrameForImageCapture()
        return filter.imageFromCurrentFramebuffer()
    }

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
                try videoCamera?.inputCamera.torchMode = newValue ? .on : .off
                try? videoCamera?.inputCamera.unlockForConfiguration()
            }

            session.commitConfiguration()
        }
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

private extension LiveVideoCapture {

    fileprivate func createVideoCamera() -> GPUImageVideoCamera? {
        let videoCamera = GPUImageVideoCamera(sessionPreset: videoConfiguration.sessionPreset.avSessionPreset.rawValue, cameraPosition: .front)
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
    func createUIElementInput() -> GPUImageUIElement {
        return GPUImageUIElement(view: self.waterMarkContentView)
    }

    func createBlendFilter() -> GPUImageAlphaBlendFilter {
        let blendFilter = GPUImageAlphaBlendFilter()
        blendFilter.mix = 1.0
        blendFilter.disableSecondFrameCheck()

        return blendFilter
    }

    func createWaterMarkContentView() -> UIView {
        let waterMarkContentView = UIView()
        waterMarkContentView.frame = CGRect(x: 0, y: 0, width: videoConfiguration.internalVideoSize.width, height: videoConfiguration.internalVideoSize.height)
        waterMarkContentView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        return waterMarkContentView
    }

    func createMovieWriterIfNeeded() {
        guard let url = saveLocalVideoPath, saveLocalVideo else { return }

        self.movieWriter = MovieWriter(url: url, size: videoConfiguration.internalVideoSize)
    }
}

// handle image processing
private extension LiveVideoCapture {
    func processVideo(output: GPUImageOutput) {
        autoreleasepool { [weak self] in
            guard let self = self, let imageFrameBuffer = output.framebufferForOutput() as? GPUImageFramebuffer else {
                return
            }

            var pifxelBuffer: CVPixelBuffer?
            CVPixelBufferCreateWithBytes(kCFAllocatorDefault, Int(videoConfiguration.internalVideoSize.width), Int(videoConfiguration.internalVideoSize.height), kCVPixelFormatType_32BGRA, imageFrameBuffer.byteBuffer(), Int(videoConfiguration.internalVideoSize.width * 4), nil, nil, nil, &pifxelBuffer)

            delegate?.captureOutput(capture: self, pixelBuffer: pifxelBuffer)
        }
    }

    func reloadFilter() {

        cleanFilterIfNeeded()

        setupBeautyFace()

        reloadMirror()

        setupCrop()

        setupWarterMark()

        adjustOutputSize()

        passRawData()
    }

    func cleanFilterIfNeeded() {
        filter?.removeAllTargets()
        blendFilter?.removeAllTargets()
        uiElementInput?.removeAllTargets()
        videoCamera?.removeAllTargets()
        output?.removeAllTargets()
        cropFilter?.removeAllTargets()
    }

    func setupBeautyFace() {
        //        if (self.beautyFace) {
        //            self.output = [[LFGPUImageEmptyFilter alloc] init];
        //            self.filter = [[LFGPUImageBeautyFilter alloc] init];
        //            self.beautyFilter = (LFGPUImageBeautyFilter*)self.filter;
        //        } else {
        //            self.output = [[LFGPUImageEmptyFilter alloc] init];
        //            self.filter = [[LFGPUImageEmptyFilter alloc] init];
        //            self.beautyFilter = nil;
        //        }

        let filter = GPUImageFilter()
        self.output = GPUImageFilter()
        self.filter = filter
    }

    //< 调节镜像
    func setupCrop() {
        //< 480*640 比例为4:3  强制转换为16:9
        if videoConfiguration.avSessionPreset == .vga640x480 {
            let cropRect = videoConfiguration.isLandscape ? CGRect(x: 0, y: 0.125, width: 1, height: 0.75) : CGRect(x: 0.125, y: 0, width: 0.75, height: 1)

            cropFilter = GPUImageCropFilter(cropRegion: cropRect)
            videoCamera?.addTarget(cropFilter)
            cropFilter?.addTarget(filter)
        } else {
            videoCamera?.addTarget(filter)
        }
    }

    //< 添加水印
    func setupWarterMark() {
        if let waterMarkView = warterMarkView {
            filter?.addTarget(blendFilter)
            uiElementInput?.addTarget(blendFilter)
            blendFilter?.addTarget(previewImageView)
            if saveLocalVideo {
                output?.addTarget(movieWriter?.writer)
            }

            filter?.addTarget(output)
            uiElementInput?.update()
        } else {
            filter?.addTarget(output)
            output?.addTarget(previewImageView)

            if saveLocalVideo {
                output?.addTarget(movieWriter?.writer)
            }
        }

    }

    func adjustOutputSize() {
        filter?.forceProcessing(at: videoConfiguration.internalVideoSize)
        output?.forceProcessing(at: videoConfiguration.internalVideoSize)
        blendFilter?.forceProcessing(at: videoConfiguration.internalVideoSize)
        uiElementInput?.forceProcessing(at: videoConfiguration.internalVideoSize)
    }

    //< 输出数据
    func passRawData() {
        output?.frameProcessingCompletionBlock = { [weak self]output, time in
            guard let output = output else { return }
            self?.processVideo(output: output)
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
