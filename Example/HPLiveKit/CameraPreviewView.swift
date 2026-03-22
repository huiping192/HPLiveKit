import SwiftUI
import AVFoundation
import HPLiveKit

/// Forces the library's AutoLayout-constrained PreviewView subview to fill its bounds
/// on every UIKit layout pass, since SwiftUI may set the hosting view's frame without
/// going through the UIKit layout cycle.
private final class CaptureContainerView: UIView {
    override func layoutSubviews() {
        super.layoutSubviews()
        subviews.forEach { $0.frame = bounds }
    }
}

/// .id(ObjectIdentifier(session)) on the call site forces recreation when session changes.
struct CameraPreviewView: UIViewRepresentable {
    let session: LiveSession

    func makeUIView(context: Context) -> UIView {
        let view = CaptureContainerView()
        view.backgroundColor = .black
        session.preview = view
        if let previewLayer = view.subviews.first?.layer as? AVCaptureVideoPreviewLayer {
            previewLayer.videoGravity = .resizeAspectFill
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        uiView.setNeedsLayout()
    }
}
