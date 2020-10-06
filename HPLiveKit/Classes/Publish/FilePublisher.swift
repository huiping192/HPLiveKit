//
//  FilePublisher.swift
//  HPLiveKit
//
//  Created by Huiping Guo on 2018/08/20.
//  Copyright © 2018 Huiping Guo. All rights reserved.
//

import Foundation
import HPLibRTMP

class FilePublisher: NSObject {

    private let handleQueue = DispatchQueue.global(qos: .default)

    private var fileHandle: FileHandle?

    private var fileName: String = ""

    private var patch: String {
        guard let documentsPath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first else {
            fatalError("cannot find document path")
        }
        
        let timestamp = Date().timeIntervalSince1970
        return documentsPath + "/video_\(timestamp).h264"
    }
    
    private var naluHeader: Data {
        let header: [UInt8] = [0x00, 0x00, 0x00, 0x01]
        return Data(bytes: header)
    }

    override init() {
        super.init()

        try? FileManager.default.createFile(atPath: patch, contents: nil, attributes: nil)
        fileHandle = FileHandle(forWritingAtPath: patch)
    }

    func save(frame: Frame) {
        guard let frame = frame as? VideoFrame else { return }

        handleQueue.async {
            self.saveVideoFrame(frame)
        }
    }

    private func saveVideoFrame(_ frame: VideoFrame) {
        handleQueue.async {
            if frame.isKeyFrame {
                self.save(sps: frame.sps!, pps: frame.pps!)
                self.save(frameData: frame.data!)
                return
            }
            
            self.save(frameData: frame.data!)
        }
    }

    private func save(sps: Data, pps: Data) {
        fileHandle?.write(naluHeader)
        fileHandle?.write(sps)

        fileHandle?.write(naluHeader)
        fileHandle?.write(pps)
    }

    private func save(frameData: Data) {
        fileHandle?.write(naluHeader)
        fileHandle?.write(frameData)
    }
}
