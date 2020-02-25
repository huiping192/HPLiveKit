//
//  Publisher.swift
//  HPLiveKit
//
//  Created by Huiping Guo on 2020/02/25.
//

import Foundation

protocol Publisher {
    func start()
    func stop()

    func send(frame: Frame)
}
