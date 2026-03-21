import AVFoundation
import HPLiveKitCore

extension LiveVideoSessionPreset {
  var avSessionPreset: AVCaptureSession.Preset {
    switch self {
    case .preset360x640:
      return .vga640x480
    case .preset540x960:
      return .iFrame960x540
    case .preset720x1280:
      return .hd1280x720
    }
  }
}

extension LiveVideoConfiguration {
  var avSessionPreset: AVCaptureSession.Preset {
    sessionPreset.avSessionPreset
  }
}
