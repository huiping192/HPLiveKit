import Foundation
import AVFoundation

extension CMAudioFormatDescription {
  
  var streamBasicDesc: AudioStreamBasicDescription? {
    get {
      return CMAudioFormatDescriptionGetStreamBasicDescription(self)?.pointee
    }
  }
}

extension CMSampleBuffer {
  var audioRawData: Data {
    var audioBufferList = AudioBufferList()
    var data = Data()
    var blockBuffer: CMBlockBuffer?
    
    CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(self, bufferListSizeNeededOut: nil, bufferListOut: &audioBufferList, bufferListSize: MemoryLayout<AudioBufferList>.size, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &blockBuffer)
    
    let buffers = UnsafeBufferPointer<AudioBuffer>(start: &audioBufferList.mBuffers, count: Int(audioBufferList.mNumberBuffers))
    
    for audioBuffer in buffers {
      let frame = audioBuffer.mData?.assumingMemoryBound(to: UInt8.self)
      data.append(frame!, count: Int(audioBuffer.mDataByteSize))
    }
    return data
  }
}

