//
//  AudioCapture.swift
//  HPLiveKit
//
//  Created by Huiping Guo on 2018/08/20.
//  Copyright © 2018 Huiping Guo. All rights reserved.
//

import Foundation
import AudioToolbox
import AVFoundation

let HPAudioComponentFailedToCreateNotification = Notification.Name(rawValue: "AudioComponentFailedToCreateNotification")

protocol AudioCaptureDelegate: class {
    /** LFAudioCapture callback audioData */
    func captureOutput(capture: LiveAudioCapture, audioData: Data)
}

class LiveAudioCapture {

    weak var delegate: AudioCaptureDelegate?

    static var current: LiveAudioCapture?
    /** The muted control callbackAudioData,muted will memset 0.*/
    var muted: Bool = false

    private var _running: Bool = false
    /** The running control start capture or stop capture*/
    var running: Bool {
        get {
            _running
        }
        set {
            guard newValue != _running else { return }

            if !newValue {
                taskQueue.async { [weak self] in
                    self?._running = false
                    guard let componentInstance = self?.componentInstance else { return }
                    AudioOutputUnitStop(componentInstance)
                }
                return
            }

            taskQueue.async { [weak self] in
                guard let self = self else { return }
                self._running = true

                var categoryOptions: AVAudioSession.CategoryOptions
                if #available(iOS 9.0, *) {
                    categoryOptions = [.defaultToSpeaker, .interruptSpokenAudioAndMixWithOthers]
                } else {
                    categoryOptions = [.defaultToSpeaker]
                }

                try? self.session.setCategory(AVAudioSessionCategoryPlayAndRecord, with: categoryOptions)
                guard let componentInstance = self.componentInstance else { return }
                AudioOutputUnitStart(componentInstance)
            }
        }
    }

    private var session: AVAudioSession = .sharedInstance()
    private var componentInstance: AudioComponentInstance?
    private var component: AudioComponent?

    private let taskQueue = DispatchQueue(label: "com.huiping192.HPLiveKit.audioCapture.Queue")

    private var configuration: LiveAudioConfiguration

    init(configuration: LiveAudioConfiguration) {
        self.configuration = configuration

        LiveAudioCapture.current = self

        configureNotifications()

        configureAudioComponent()
        configureAudioComponetInstance()
        configureAudioSession()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)

        taskQueue.sync {
            guard let componentInstance = componentInstance else { return }
            self.running = false
            AudioOutputUnitStop(componentInstance)
            AudioComponentInstanceDispose(componentInstance)
            self.componentInstance = nil
            self.component = nil
        }
    }

    var handleInputBuffer: AURenderCallback = {(
        inRefCon: UnsafeMutableRawPointer,
        ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        inTimeStamp: UnsafePointer<AudioTimeStamp>,
        inBusNumber: UInt32,
        inNumberFrames: UInt32,
        ioData: UnsafeMutablePointer<AudioBufferList>?) in

        guard let source = LiveAudioCapture.current, let componetInstance = source.componentInstance else {
            return -1
        }

        var status = noErr

        let channelCount: UInt32 = 1

        var bufferList = AudioBufferList()
        bufferList.mNumberBuffers = channelCount
        let buffers = UnsafeMutableBufferPointer<AudioBuffer>(start: &bufferList.mBuffers,
                                                              count: Int(bufferList.mNumberBuffers))
        buffers[0].mNumberChannels = 1
        buffers[0].mDataByteSize = inNumberFrames * 2
        buffers[0].mData = nil

        // get the recorded samples
        status = AudioUnitRender(componetInstance,
                                 ioActionFlags,
                                 inTimeStamp,
                                 inBusNumber,
                                 inNumberFrames,
                                 UnsafeMutablePointer<AudioBufferList>(&bufferList))
        if status != noErr {
            return status
        }

        let data = Data(bytes: buffers[0].mData!, count: Int(buffers[0].mDataByteSize))
        source.delegate?.captureOutput(capture: source, audioData: data)

        return status

    }
}

// notification
private extension LiveAudioCapture {
    func configureNotifications() {
        NotificationCenter.default.addObserver(self, selector: #selector(self.handleRouteChange(notification:)), name: Notification.Name.AVAudioSessionRouteChange, object: nil)

        NotificationCenter.default.addObserver(self, selector: #selector(self.handleInterruption(notification:)), name: Notification.Name.AVAudioSessionInterruption, object: nil)
    }

    @objc func handleRouteChange(notification: Notification) {
        var seccReason = ""
        guard let routeChangeReasonNumber = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber  else {
            return
        }
        var reason = routeChangeReasonNumber.intValue

        let routeChangeReason = AVAudioSession.RouteChangeReason(rawValue: UInt(reason)) ?? AVAudioSession.RouteChangeReason.unknown
        switch routeChangeReason {
        case AVAudioSession.RouteChangeReason.noSuitableRouteForCategory:
            seccReason = "The route changed because no suitable route is now available for the specified category."
        case AVAudioSession.RouteChangeReason.wakeFromSleep:
            seccReason = "The route changed when the device woke up from sleep."
        case AVAudioSession.RouteChangeReason.override:
            seccReason = "The output route was overridden by the app."
        case AVAudioSession.RouteChangeReason.categoryChange:
            seccReason = "The category of the session object changed."
        case AVAudioSession.RouteChangeReason.oldDeviceUnavailable:
            seccReason = "The previous audio output path is no longer available."
        case AVAudioSession.RouteChangeReason.newDeviceAvailable:
            seccReason = "A preferred new audio output path is now available."
        case AVAudioSession.RouteChangeReason.unknown:
            seccReason = "The reason for the change is unknown."
        default:
            seccReason = "The reason for the change is unknown."
        }

        print("handleRouteChange reason is \(seccReason)")

        let input = session.currentRoute.inputs.first
        if input?.portType == AVAudioSessionPortHeadsetMic {

        }
    }

    @objc func handleInterruption(notification: Notification) {
        var reason = 0
        var reasonStr = ""

        if notification.name == NSNotification.Name.AVAudioSessionInterruption {
            //Posted when an audio interruption occurs.

            guard let reasonNumber = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber  else {
                return
            }
            var reason = reasonNumber.intValue

            if reason == AVAudioSession.InterruptionType.began.rawValue && running {
                guard let componetInstance = componentInstance else { return }
                taskQueue.sync {
                    print("MicrophoneSource: stopRunning")
                    AudioOutputUnitStop(componetInstance)
                }
            }

            if reason == AVAudioSession.InterruptionType.ended.rawValue {
                reasonStr = "AVAudioSessionInterruptionTypeEnded"

                guard let reasonNumber = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? NSNumber  else {
                    return
                }
                var seccondReason = reasonNumber.intValue

                if seccondReason == AVAudioSession.InterruptionOptions.shouldResume.rawValue && running {
                    guard let componetInstance = componentInstance else { return }
                    taskQueue.sync {
                        print("MicrophoneSource: startRunning")
                        AudioOutputUnitStart(componetInstance)
                    }
                }
            }

            print("handleInterruption: \(notification.name.rawValue) reason \(reasonStr)")
        }
    }

    func handleAudioComponentCreationFailure() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: HPAudioComponentFailedToCreateNotification, object: nil)
        }
    }

}

extension LiveAudioCapture {
    func configureAudioComponent() {
        var acd: AudioComponentDescription = AudioComponentDescription()
        acd.componentType = kAudioUnitType_Output
        acd.componentSubType = kAudioUnitSubType_RemoteIO
        acd.componentManufacturer = kAudioUnitManufacturer_Apple
        acd.componentFlags = 0
        acd.componentFlagsMask = 0

        component = AudioComponentFindNext(nil, &acd)

    }

    func configureAudioComponetInstance() {
        guard let component = component else { return }

        var status = noErr
        status = AudioComponentInstanceNew(component, &componentInstance)

        if status != noErr {
            handleAudioComponentCreationFailure()
        }

        guard let componetInstance = componentInstance else { return }

        var flagOne: UInt32 = 1

        AudioUnitSetProperty(componetInstance, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, kAudioUnitScope_Input, &flagOne, UInt32(MemoryLayout.size(ofValue: flagOne)))

        var desc = AudioStreamBasicDescription()

        desc.mSampleRate = Float64(configuration.audioSampleRate.rawValue)
        desc.mFormatID = kAudioFormatLinearPCM
        desc.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked
        desc.mChannelsPerFrame = UInt32(configuration.numberOfChannels)
        desc.mFramesPerPacket = 1
        desc.mBitsPerChannel = 16
        desc.mBytesPerFrame = desc.mBitsPerChannel / 8 * desc.mChannelsPerFrame
        desc.mBytesPerPacket = desc.mBytesPerFrame * desc.mFramesPerPacket

        var callbackStruct = AURenderCallbackStruct()
        callbackStruct.inputProcRefCon = nil
        callbackStruct.inputProc = handleInputBuffer
        AudioUnitSetProperty(componetInstance, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &desc, UInt32(MemoryLayout.size(ofValue: desc)))

        AudioUnitSetProperty(componetInstance, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 1, &callbackStruct, UInt32(MemoryLayout.size(ofValue: callbackStruct)))

        status = AudioUnitInitialize(componetInstance)
        if status != noErr {
            handleAudioComponentCreationFailure()
        }
    }

    func configureAudioSession() {
        try? session.setPreferredSampleRate(Double(configuration.audioSampleRate.rawValue))
        var categoryOptions: AVAudioSession.CategoryOptions
        if #available(iOS 9.0, *) {
            categoryOptions = [.defaultToSpeaker, .interruptSpokenAudioAndMixWithOthers]
        } else {
            categoryOptions = [.defaultToSpeaker]
        }
        try? session.setCategory(AVAudioSessionCategoryPlayAndRecord, with: categoryOptions)

        try? session.setActive(true, with: [.notifyOthersOnDeactivation])
        try? session.setActive(true)
    }

}
