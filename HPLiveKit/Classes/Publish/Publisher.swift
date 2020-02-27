//
//  Publisher.swift
//  HPLiveKit
//
//  Created by Huiping Guo on 2020/02/25.
//

import Foundation

//@protocol LFStreamSocketDelegate <NSObject>
//
///** callback buffer current status (回调当前缓冲区情况，可实现相关切换帧率 码率等策略)*/
//- (void)socketBufferStatus:(nullable id <LFStreamSocket>)socket status:(LFLiveBuffferState)status;
///** callback socket current status (回调当前网络情况) */
//- (void)socketStatus:(nullable id <LFStreamSocket>)socket status:(LFLiveState)status;
///** callback socket errorcode */
//- (void)socketDidError:(nullable id <LFStreamSocket>)socket errorCode:(LFLiveSocketErrorCode)errorCode;
//@optional
///** callback debugInfo */
//- (void)socketDebug:(nullable id <LFStreamSocket>)socket debugInfo:(nullable LFLiveDebug *)debugInfo;
//@end

protocol PublisherDelegate: class {
    //    func publisher(publisher: Publisher, status)
}

protocol Publisher {

    var delegate: PublisherDelegate? {
        get
        set
    }

    func start()
    func stop()

    func send(frame: Frame)
}
