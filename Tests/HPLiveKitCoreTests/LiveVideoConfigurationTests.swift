//
//  LiveVideoConfigurationTests.swift
//

import XCTest
@testable import HPLiveKitCore

final class LiveVideoConfigurationTests: XCTestCase {

    private func makeConfig(
        size: CGSize = CGSize(width: 540, height: 960),
        orientation: VideoOutputOrientation = .portrait,
        respectAspectRatio: Bool = false,
        preset: LiveVideoSessionPreset = .preset540x960
    ) -> LiveVideoConfiguration {
        LiveVideoConfiguration(
            videoSize: size,
            videoSizeRespectingAspectRatio: respectAspectRatio,
            outputImageOrientation: orientation,
            autorotate: true,
            videoFrameRate: 30,
            videoMinFrameRate: 15,
            videoMaxFrameRate: 30,
            videoBitRate: 800_000,
            videoMaxBitRate: 1_000_000,
            videoMinBitRate: 300_000,
            sessionPreset: preset
        )
    }

    func testIsLandscape_Portrait() {
        let config = makeConfig(orientation: .portrait)
        XCTAssertFalse(config.isLandscape)
    }

    func testIsLandscape_LandscapeLeft() {
        let config = makeConfig(orientation: .landscapeLeft)
        XCTAssertTrue(config.isLandscape)
    }

    func testIsLandscape_LandscapeRight() {
        let config = makeConfig(orientation: .landscapeRight)
        XCTAssertTrue(config.isLandscape)
    }

    func testOrientationFormatVideoSize_Portrait_Unchanged() {
        let config = makeConfig(size: CGSize(width: 540, height: 960), orientation: .portrait)
        XCTAssertEqual(config.orientationFormatVideoSize, CGSize(width: 540, height: 960))
    }

    func testOrientationFormatVideoSize_Landscape_Swapped() {
        let config = makeConfig(size: CGSize(width: 540, height: 960), orientation: .landscapeLeft)
        XCTAssertEqual(config.orientationFormatVideoSize, CGSize(width: 960, height: 540))
    }

    func testVideoMaxKeyframeInterval_IsDoubleFrameRate() {
        let config = makeConfig()
        XCTAssertEqual(config.videoMaxKeyframeInterval, 60) // 30 * 2
    }

    func testAspectRatioVideoSize_EvenDimensions() {
        // 540x960 portrait, preset 540x960 → should fit exactly
        let config = makeConfig(
            size: CGSize(width: 540, height: 960),
            orientation: .portrait,
            respectAspectRatio: true,
            preset: .preset540x960
        )
        let result = config.aspectRatioVideoSize
        XCTAssertEqual(Int(result.width) % 2, 0, "Width must be even")
        XCTAssertEqual(Int(result.height) % 2, 0, "Height must be even")
    }

    func testAspectRatioVideoSize_AlwaysEvenForLandscape() {
        let config = makeConfig(
            size: CGSize(width: 960, height: 540),
            orientation: .landscapeLeft,
            respectAspectRatio: true,
            preset: .preset540x960
        )
        let result = config.aspectRatioVideoSize
        XCTAssertEqual(Int(result.width) % 2, 0)
        XCTAssertEqual(Int(result.height) % 2, 0)
    }

    func testInternalVideoSize_WithoutAspectRatio_UsesOrientationSize() {
        let config = makeConfig(
            size: CGSize(width: 540, height: 960),
            orientation: .landscapeLeft,
            respectAspectRatio: false
        )
        XCTAssertEqual(config.internalVideoSize, CGSize(width: 960, height: 540))
    }

    func testInternalVideoSize_WithAspectRatio_UsesAspectRatioSize() {
        let config = makeConfig(
            size: CGSize(width: 540, height: 960),
            orientation: .portrait,
            respectAspectRatio: true,
            preset: .preset540x960
        )
        let result = config.internalVideoSize
        // Should be the aspect-ratio-fitted size
        XCTAssertEqual(result, config.aspectRatioVideoSize)
    }
}
