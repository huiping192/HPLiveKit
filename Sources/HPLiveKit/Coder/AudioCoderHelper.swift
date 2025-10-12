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

    #if DEBUG
    // Diagnostic logging for audio format
    if let formatDesc = CMSampleBufferGetFormatDescription(self),
       let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee {
      print("[AudioCoderHelper] Audio Buffer Info:")
      print("  Number of buffers: \(audioBufferList.mNumberBuffers)")
      print("  Format ID: 0x\(String(format: "%X", asbd.mFormatID))")
      print("  Format Flags: 0x\(String(format: "%X", asbd.mFormatFlags))")

      // Check if non-interleaved
      let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
      print("  Is Non-Interleaved (planar): \(isNonInterleaved)")
      print("  Channels per frame: \(asbd.mChannelsPerFrame)")

      for (index, audioBuffer) in buffers.enumerated() {
        print("  Buffer[\(index)]: channels=\(audioBuffer.mNumberChannels), size=\(audioBuffer.mDataByteSize) bytes")
      }

      if audioBufferList.mNumberBuffers > 1 {
        print("  ⚠️  WARNING: Multiple buffers detected! This might be non-interleaved audio.")
        print("  Current code will concatenate buffers sequentially, which is WRONG for interleaved encoding!")
      }
    }
    #endif

    for audioBuffer in buffers {
      let frame = audioBuffer.mData?.assumingMemoryBound(to: UInt8.self)
      data.append(frame!, count: Int(audioBuffer.mDataByteSize))
    }
    return data
  }
}

