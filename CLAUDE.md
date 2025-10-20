# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

HPLiveKit 是一个用 Swift 编写的 iOS RTMP 直播推流库，支持视频和音频的实时采集、编码和推流。

## Build Commands

### 使用 Swift Package Manager
```bash
# 构建项目
swift build

# 运行测试
swift test
```

### 使用 Xcode
```bash
# 打开示例项目
open Example/HPLiveKit.xcodeproj

# 使用 xcodebuild 构建示例项目
xcodebuild -project Example/HPLiveKit.xcodeproj -scheme HPLiveKit-Example -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -configuration Debug build

# Resolve SPM dependencies
xcodebuild -resolvePackageDependencies -project Example/HPLiveKit.xcodeproj -scheme HPLiveKit-Example
```

## Architecture Overview

HPLiveKit 采用分层架构设计，核心组件职责清晰：

### 核心类: LiveSession (Sources/HPLiveKit/LiveSession.swift)
- 整个直播会话的控制中心
- 协调 CaptureManager、EncoderManager 和 Publisher 三大组件
- 管理直播状态和流程控制
- 支持两种模式：
  - `.camera` - 相机采集模式（默认）
  - `.screenShare` - 屏幕共享模式（用于 RPBroadcastSampleHandler）
- 主要 API:
  - `init(audioConfiguration:videoConfiguration:mode:)` - 通用初始化器
  - `init(forScreenShare:videoEncodingQuality:audioEncodingQuality:)` - 屏幕共享专用初始化器
  - `startLive(streamInfo:)` - 开始推流
  - `stopLive()` - 停止推流
  - `startCapturing()` / `stopCapturing()` - 控制音视频采集（仅 camera 模式）
  - `pushVideo(_:)` - 推送视频帧（仅 screenShare 模式）
  - `pushAppAudio(_:)` - 推送应用音频（仅 screenShare 模式）
  - `pushMicAudio(_:)` - 推送麦克风音频（预留，暂未实现）
  - `preview` - 设置预览视图（仅 camera 模式）
  - `mute` - 音频静音控制（仅 camera 模式）

### 三大核心模块

1. **Capture（采集层）** - Sources/HPLiveKit/Capture/
   - `CaptureManager`: 统一管理音视频采集
   - `LiveVideoCapture`: 使用 AVCaptureSession 采集摄像头视频
   - `LiveAudioCapture`: 采集麦克风音频
   - 输出 CMSampleBuffer 格式的原始数据

2. **Coder（编码层）** - Sources/HPLiveKit/Coder/
   - `EncoderManager`: 统一管理音视频编码
   - `LiveVideoH264Encoder`: 使用 VideoToolbox 进行 H.264 硬件编码
   - `AudioEncoder`: 使用 AudioToolbox 进行 AAC 硬件编码
   - 输出编码后的 VideoFrame 和 AudioFrame

3. **Publish（推流层）** - Sources/HPLiveKit/Publish/
   - `RtmpPublisher`: RTMP 推流实现（使用 Swift 6 Actor 模型确保线程安全）
   - `StreamingBuffer`: 管理待发送帧的缓冲队列，支持丢帧策略
   - 依赖 HPRTMP 库进行底层 RTMP 协议处理
   - 支持自动重连机制

### 数据流转
```
Camera/Mic -> CaptureManager -> EncoderManager -> Publisher -> RTMP Server
             (CMSampleBuffer)    (AudioFrame/VideoFrame)   (RTMP Packets)
```

### Configuration（配置）
- `LiveVideoConfiguration`: 视频配置（分辨率、帧率、码率等）
- `LiveAudioConfiguration`: 音频配置（采样率、码率等）
- `LiveVideoQuality`: 预定义的视频质量等级（low1-3, medium1-3, high1-3）

### 关键特性

1. **自适应码率**: LiveSession 根据 StreamingBuffer 的状态自动调整视频码率（50Kbps 步进增加，100Kbps 步进减少）

2. **帧同步策略**:
   - 必须先收到音频帧（`hasCapturedAudio`）
   - 必须收到关键帧（`hasCapturedKeyFrame`）
   - 两个条件都满足后才开始正式推流

3. **并发安全**:
   - RtmpPublisher 使用 Swift 6 的 Actor 模型
   - 所有网络操作在 actor 隔离域内执行

## Dependencies

- HPRTMP: RTMP 协议底层实现 (https://github.com/huiping192/HPRTMP.git)
- iOS 14.0+
- Swift 6.0+

## Usage Examples

### 相机采集模式（默认）

```swift
// 1. 创建 LiveSession
let audioConfig = LiveAudioConfigurationFactory.defaultAudioConfiguration
let videoConfig = LiveVideoConfigurationFactory.defaultVideoConfiguration
let liveSession = LiveSession(audioConfiguration: audioConfig,
                               videoConfiguration: videoConfig)

// 2. 设置预览视图
liveSession.preview = previewView

// 3. 开始采集
liveSession.startCapturing()

// 4. 开始推流
let streamInfo = LiveStreamInfo(url: "rtmp://your-server/live/stream")
liveSession.startLive(streamInfo: streamInfo)

// 5. 停止推流
liveSession.stopLive()
liveSession.stopCapturing()
```

### 屏幕共享模式（RPBroadcastSampleHandler）

```swift
// 在 RPBroadcastSampleHandler 中使用
import ReplayKit
import HPLiveKit

class SampleHandler: RPBroadcastSampleHandler {
    var liveSession: LiveSession?

    override func broadcastStarted(withSetupInfo setupInfo: [String : NSObject]?) {
        // 1. 创建屏幕共享专用 LiveSession
        liveSession = LiveSession(
            forScreenShare: (),
            videoEncodingQuality: .high1,
            audioEncodingQuality: .high
        )

        // 2. 开始推流
        let streamInfo = LiveStreamInfo(url: "rtmp://your-server/live/stream")
        liveSession?.startLive(streamInfo: streamInfo)
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer,
                                      with sampleBufferType: RPSampleBufferType) {
        switch sampleBufferType {
        case .video:
            liveSession?.pushVideo(sampleBuffer)
        case .audioApp:
            liveSession?.pushAppAudio(sampleBuffer)
        case .audioMic:
            // 暂不支持，预留接口
            // liveSession?.pushMicAudio(sampleBuffer)
            break
        @unknown default:
            break
        }
    }

    override func broadcastFinished() {
        liveSession?.stopLive()
        liveSession = nil
    }
}
```

## Testing

测试文件位于 `Tests/HPLiveKitTests/`，目前测试覆盖较少，主要是基础的初始化测试。

## Code Style

项目使用 SwiftLint 进行代码规范检查，配置文件: `Example/.swiftlint.yml`
- 禁用规则: identifier_name, line_length
- 包含路径: ../HPLiveKit
- 排除路径: Pods
