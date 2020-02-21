//
//  MovieWriter.swift
//  HPLiveKit
//
//  Created by Huiping Guo on 2020/02/22.
//

import Foundation
import GPUImage

class MovieWriter {
    private(set) var writer: GPUImageMovieWriter?

    let url: URL
    let size: CGSize

    init(url: URL, size: CGSize) {
        self.url = url
        self.size = size

        let writer = GPUImageMovieWriter(movieURL: url, size: size)
        writer?.encodingLiveVideo = true
        writer?.shouldPassthroughAudio = true
    }

    func start() {
        writer?.startRecording()
    }

    func stop() {
        writer?.finishRecording()
    }
}
