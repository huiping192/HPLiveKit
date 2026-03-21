import Foundation
import CoreMedia

extension CMBlockBuffer {
  var data: Data? {
    var length: Int = 0
    var pointer: UnsafeMutablePointer<Int8>?
    guard CMBlockBufferGetDataPointer(self, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
          let p = pointer else {
      return nil
    }
    return Data(bytes: p, count: length)
  }
  
  var length: Int {
    return CMBlockBufferGetDataLength(self)
  }
  
}
