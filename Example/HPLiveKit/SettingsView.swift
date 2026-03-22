import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: LiveViewModel
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        NavigationView {
            Form {
                rtmpSection
                videoQualitySection
                audioQualitySection
                advancedSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        }
        .onDisappear {
            viewModel.applySettings()
        }
    }

    // MARK: - Sections

    private var rtmpSection: some View {
        Section(header: Text("RTMP SERVER")) {
            TextField("rtmp://host/app/stream", text: $viewModel.rtmpURL)
                .keyboardType(.URL)
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .font(.system(size: 14, design: .monospaced))
        }
    }

    private var videoQualitySection: some View {
        Section(header: Text("VIDEO QUALITY")) {
            ForEach(0..<LiveViewModel.videoQualities.count, id: \.self) { index in
                let option = LiveViewModel.videoQualities[index]
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(option.name)
                        Text(option.detail)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if viewModel.videoQualityIndex == index {
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.accentColor)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    viewModel.videoQualityIndex = index
                }
            }
        }
    }

    private var audioQualitySection: some View {
        Section(header: Text("AUDIO QUALITY")) {
            ForEach(0..<LiveViewModel.audioQualities.count, id: \.self) { index in
                let option = LiveViewModel.audioQualities[index]
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(option.name)
                        Text(option.detail)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if viewModel.audioQualityIndex == index {
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.accentColor)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    viewModel.audioQualityIndex = index
                }
            }
        }
    }

    private var advancedSection: some View {
        Section(header: Text("ADVANCED")) {
            Toggle("Adaptive Bitrate", isOn: $viewModel.adaptiveBitrate)
            Toggle("Show Debug Stats", isOn: $viewModel.showDebugStats)
        }
    }
}
