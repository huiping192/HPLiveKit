import SwiftUI
import HPLiveKit

struct LiveView: View {
    @StateObject private var viewModel = LiveViewModel()
    @State private var showSettings = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            CameraPreviewView(session: viewModel.session)
                .id(ObjectIdentifier(viewModel.session))
                .ignoresSafeArea()

            // Controls overlay respects safe area so topBar sits below status bar
            VStack(spacing: 0) {
                topBar
                Spacer()
                bottomArea
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(viewModel: viewModel)
        }
        .alert(isPresented: $viewModel.showError) {
            Alert(
                title: Text("Streaming Error"),
                message: Text(viewModel.errorMessage ?? ""),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(alignment: .center) {
            statusIndicator
            Spacer()
            settingsButton
        }
        .padding(.top, 8)
    }

    private var statusIndicator: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(stateColor)
                .frame(width: 8, height: 8)
                .opacity(stateBlinking ? 1 : 0.3)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                           value: stateBlinking)
            Text(stateText)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.55))
        .clipShape(Capsule())
    }

    private var settingsButton: some View {
        Button { showSettings = true } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(.white)
                .frame(width: 40, height: 40)
                .background(Color.black.opacity(0.55))
                .clipShape(Circle())
        }
    }

    // MARK: - Bottom area

    private var bottomArea: some View {
        VStack(alignment: .leading, spacing: 12) {
            if viewModel.showDebugStats, let debug = viewModel.debugInfo {
                DebugStatsView(debug: debug)
            }

            HStack(spacing: 0) {
                muteButton
                Spacer()
                publishButton
                Spacer()
                flipButton
            }
            .padding(.bottom, 16)
        }
    }

    // MARK: - Control buttons

    private var muteButton: some View {
        controlButton(
            icon: viewModel.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
            tint: viewModel.isMuted ? .orange : .white,
            action: viewModel.toggleMute
        )
    }

    private var publishButton: some View {
        let isPending = viewModel.liveState == .pending || viewModel.liveState == .refresh
        let isLive = viewModel.liveState == .start

        return Button(action: viewModel.togglePublish) {
            ZStack {
                Circle()
                    .fill(isLive ? Color.red.opacity(0.75) : Color.black.opacity(0.55))
                    .frame(width: 72, height: 72)

                if isPending {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(1.3)
                } else {
                    Image(systemName: isLive ? "stop.fill" : "record.circle.fill")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundColor(.white)
                }
            }
        }
        .disabled(isPending)
    }

    private var flipButton: some View {
        controlButton(
            icon: "camera.rotate.fill",
            tint: .white,
            action: viewModel.toggleCamera
        )
    }

    private func controlButton(icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(tint)
                .frame(width: 52, height: 52)
                .background(Color.black.opacity(0.55))
                .clipShape(Circle())
        }
    }

    // MARK: - State helpers

    private var stateColor: Color {
        switch viewModel.liveState {
        case .ready:              return .gray
        case .pending, .refresh:  return .yellow
        case .start:              return .green
        case .stop:               return .gray
        case .error:              return .red
        @unknown default:         return .gray
        }
    }

    private var stateBlinking: Bool {
        viewModel.liveState == .pending || viewModel.liveState == .refresh
    }

    private var stateText: String {
        switch viewModel.liveState {
        case .ready:    return "Ready"
        case .pending:  return "Connecting..."
        case .start:    return "Live \(formatElapsed(viewModel.elapsedSeconds))"
        case .stop:     return "Stopped"
        case .error:    return "Error"
        case .refresh:  return "Reconnecting..."
        @unknown default: return "Unknown"
        }
    }

    private func formatElapsed(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        } else {
            return String(format: "%02d:%02d", m, s)
        }
    }
}

// MARK: - Debug stats overlay

private struct DebugStatsView: View {
    let debug: LiveDebug

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            row("BW",    formatBandwidth(debug.bandwidthPerSec))
            row("FPS",   "V:\(debug.capturedVideoCountPerSec) A:\(debug.capturedAudioCountPerSec)")
            row("Drop",  "\(debug.dropFrameCount)/\(debug.totalFrameCount)")
            row("Buf",   "\(debug.unsendCount)")
            row("Total", formatBytes(debug.allDataSize))
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundColor(.white)
        .padding(8)
        .background(Color.black.opacity(0.6))
        .cornerRadius(8)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label + ":")
                .frame(width: 38, alignment: .leading)
                .foregroundColor(Color(white: 0.7))
            Text(value)
        }
    }

    private func formatBandwidth(_ bps: CGFloat) -> String {
        if bps >= 1_000_000 {
            return String(format: "%.1f Mbps", bps / 1_000_000)
        }
        return String(format: "%.0f Kbps", bps / 1_000)
    }

    private func formatBytes(_ bytes: CGFloat) -> String {
        if bytes >= 1_000_000 {
            return String(format: "%.1f MB", bytes / 1_000_000)
        }
        return String(format: "%.0f KB", bytes / 1_000)
    }
}
