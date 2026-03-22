import Foundation
import Combine
import HPLiveKit

@MainActor
final class LiveViewModel: ObservableObject {

    // MARK: - Quality option definitions

    struct VideoQualityOption: Sendable {
        let name: String
        let detail: String
        let factory: @Sendable () -> LiveVideoConfiguration
    }

    struct AudioQualityOption: Sendable {
        let name: String
        let detail: String
        let factory: @Sendable () -> LiveAudioConfiguration
    }

    nonisolated static let videoQualities: [VideoQualityOption] = [
        VideoQualityOption(name: "Low 1",    detail: "360×640 · 15fps · 500Kbps",   factory: LiveVideoConfigurationFactory.createLow1),
        VideoQualityOption(name: "Low 2",    detail: "360×640 · 24fps · 600Kbps",   factory: LiveVideoConfigurationFactory.createLow2),
        VideoQualityOption(name: "Low 3",    detail: "360×640 · 30fps · 800Kbps",   factory: LiveVideoConfigurationFactory.createLow3),
        VideoQualityOption(name: "Medium 1", detail: "540×960 · 15fps · 800Kbps",   factory: LiveVideoConfigurationFactory.createMedium1),
        VideoQualityOption(name: "Medium 2", detail: "540×960 · 24fps · 800Kbps",   factory: LiveVideoConfigurationFactory.createMedium2),
        VideoQualityOption(name: "Medium 3", detail: "540×960 · 30fps · 1000Kbps",  factory: LiveVideoConfigurationFactory.createMedium3),
        VideoQualityOption(name: "High 1",   detail: "720×1280 · 15fps · 1000Kbps", factory: LiveVideoConfigurationFactory.createHigh1),
        VideoQualityOption(name: "High 2",   detail: "720×1280 · 24fps · 1200Kbps", factory: LiveVideoConfigurationFactory.createHigh2),
        VideoQualityOption(name: "High 3",   detail: "720×1280 · 30fps · 1200Kbps", factory: LiveVideoConfigurationFactory.createHigh3),
    ]

    nonisolated static let audioQualities: [AudioQualityOption] = [
        AudioQualityOption(name: "Low",       detail: "16KHz · 64Kbps",    factory: LiveAudioConfigurationFactory.createLow),
        AudioQualityOption(name: "Medium",    detail: "44.1KHz · 96Kbps",  factory: LiveAudioConfigurationFactory.createMedium),
        AudioQualityOption(name: "High",      detail: "44.1KHz · 128Kbps", factory: LiveAudioConfigurationFactory.createHigh),
        AudioQualityOption(name: "Very High", detail: "48KHz · 128Kbps",   factory: LiveAudioConfigurationFactory.createVeryHigh),
    ]

    // MARK: - Session

    @Published private(set) var session: LiveSession

    // MARK: - Live state

    @Published private(set) var liveState: LiveState = .ready
    @Published var isMuted: Bool = false
    @Published var isFrontCamera: Bool = true
    @Published private(set) var debugInfo: LiveDebug?
    @Published var errorMessage: String?
    @Published var showError: Bool = false
    @Published private(set) var elapsedSeconds: Int = 0

    // MARK: - Settings (persisted to UserDefaults)

    @Published var rtmpURL: String = ""
    @Published var videoQualityIndex: Int = 8
    @Published var audioQualityIndex: Int = 2
    @Published var adaptiveBitrate: Bool = true
    @Published var showDebugStats: Bool = false

    private var timerCancellable: AnyCancellable?

    // MARK: - Init

    init() {
        let defaults = UserDefaults.standard

        let vidIdx = defaults.object(forKey: "videoQualityIndex") != nil
            ? max(0, min(8, defaults.integer(forKey: "videoQualityIndex")))
            : 8
        let audIdx = defaults.object(forKey: "audioQualityIndex") != nil
            ? max(0, min(3, defaults.integer(forKey: "audioQualityIndex")))
            : 2
        let adaptive = defaults.object(forKey: "adaptiveBitrate") as? Bool ?? true

        let videoConfig = LiveViewModel.videoQualities[vidIdx].factory()
        let audioConfig = LiveViewModel.audioQualities[audIdx].factory()
        let newSession = LiveSession(audioConfiguration: audioConfig, videoConfiguration: videoConfig)
        newSession.adaptiveVideoBitrate = adaptive
        session = newSession

        // All stored properties now initialized; self is available
        self.rtmpURL = defaults.string(forKey: "rtmpURL") ?? ""
        self.videoQualityIndex = vidIdx
        self.audioQualityIndex = audIdx
        self.adaptiveBitrate = adaptive
        self.showDebugStats = defaults.bool(forKey: "showDebugStats")

        session.delegate = self
        session.startCapturing()
    }

    // MARK: - Public actions

    func togglePublish() {
        switch liveState {
        case .ready, .stop, .error:
            let url = rtmpURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty, url.hasPrefix("rtmp://") || url.hasPrefix("rtmps://") else {
                errorMessage = "Please enter a valid RTMP URL (starting with rtmp://) in Settings."
                showError = true
                return
            }
            session.startLive(streamInfo: LiveStreamInfo(url: url))
        case .start:
            session.stopLive()
        case .pending, .refresh:
            break
        @unknown default:
            break
        }
    }

    func toggleMute() {
        isMuted.toggle()
        session.mute = isMuted
    }

    func toggleCamera() {
        isFrontCamera.toggle()
        session.captureDevicePositionFront = isFrontCamera
    }

    func applySettings() {
        let defaults = UserDefaults.standard
        defaults.set(rtmpURL, forKey: "rtmpURL")
        defaults.set(videoQualityIndex, forKey: "videoQualityIndex")
        defaults.set(audioQualityIndex, forKey: "audioQualityIndex")
        defaults.set(adaptiveBitrate, forKey: "adaptiveBitrate")
        defaults.set(showDebugStats, forKey: "showDebugStats")

        let wasLive = liveState == .start || liveState == .pending
        if wasLive { session.stopLive() }
        session.stopCapturing()

        let videoConfig = LiveViewModel.videoQualities[videoQualityIndex].factory()
        let audioConfig = LiveViewModel.audioQualities[audioQualityIndex].factory()
        let newSession = LiveSession(audioConfiguration: audioConfig, videoConfiguration: videoConfig)
        newSession.adaptiveVideoBitrate = adaptiveBitrate
        newSession.mute = isMuted
        newSession.captureDevicePositionFront = isFrontCamera
        newSession.delegate = self
        session = newSession
        session.startCapturing()

        liveState = .ready
        stopTimer()
        debugInfo = nil
    }

    // MARK: - Private helpers

    private func startTimer() {
        elapsedSeconds = 0
        timerCancellable = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.elapsedSeconds += 1
            }
    }

    private func stopTimer() {
        timerCancellable?.cancel()
        timerCancellable = nil
        elapsedSeconds = 0
    }
}

// MARK: - LiveSessionDelegate

extension LiveViewModel: LiveSessionDelegate {

    nonisolated func liveSession(session: LiveSession, liveStateDidChange state: LiveState) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.liveState = state
            switch state {
            case .start:
                self.startTimer()
            case .stop, .error, .ready:
                self.stopTimer()
            case .pending, .refresh:
                break
            @unknown default:
                break
            }
        }
    }

    nonisolated func liveSession(session: LiveSession, errorCode: LiveSocketErrorCode) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let message: String
            switch errorCode {
            case .previewFail:        message = "Camera preview setup failed."
            case .getStreamInfo:      message = "Failed to retrieve stream info."
            case .connectSocket:      message = "Connection to server failed."
            case .verification:       message = "Server authentication failed."
            case .reconnectTimeOut:   message = "Reconnection timed out."
            @unknown default:         message = "An unknown streaming error occurred."
            }
            self.errorMessage = message
            self.showError = true
        }
    }

    // LiveSession only calls the per-stream variant, not the aggregated one
    nonisolated func liveSession(session: LiveSession, streamInfo: LiveStreamInfo, debugInfo: LiveDebug) {
        Task { @MainActor [weak self] in
            self?.debugInfo = debugInfo
        }
    }
}
