# HPLiveKit

![CI](https://github.com/huiping192/HPLiveKit/workflows/CI/badge.svg)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/huiping192/HPLiveKit/blob/main/LICENSE)
[![Platform](https://img.shields.io/badge/platform-iOS%2014.0%2B-lightgrey.svg)](https://github.com/huiping192/HPLiveKit)


**Swift rtmp base live streaming lib. Inspired by LFLiveKit https://github.com/LaiFengiOS/LFLiveKit**


## Features

### video
- [x]   Video configuration
- [ ]   Beauty Face
- [ ]   WaterMark

### audio
- [x]   Audio configuration
- [x] 	 Audio Mute
- [ ]   AudioEngine support
- [ ]   Audio only broadcasting 
- [ ]   Audio broadcasting in background

### encoder
- [x]   H264 Hardware Encoding 
- [x]   AAC Hardware Encoding

### publish

- [x] 	RTMP 
- [x] 	Drop frames on bad network 
- [x] 	Dynamic switching bitRate
- [ ] 	local MP4 recording




## Example

To run the example project, clone the repo and open `Example/HPLiveKit.xcodeproj` in Xcode.

## Requirements
- iOS 14.0+
- Xcode 13+
- Swift 5.5+

## Installation

### Swift Package Manager

HPLiveKit is available through [Swift Package Manager](https://swift.org/package-manager/).

To add HPLiveKit to your Xcode project:
1. File > Add Package Dependencies
2. Enter package URL: `https://github.com/huiping192/HPLiveKit`
3. Select version or branch
4. Add to your target

Or add it to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/huiping192/HPLiveKit", from: "0.1.0")
]
```

> **Note:** CocoaPods support has been discontinued. Please use Swift Package Manager instead.

## Usage example 


## Author

Huiping Guo, huiping192@gmail.com

## Release History

## License

HPLiveKit is available under the MIT license. See the LICENSE file for more info.
