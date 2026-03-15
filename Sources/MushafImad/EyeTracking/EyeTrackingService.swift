//
//  EyeTrackingService.swift
//  MushafImad
//
//  Eye-tracking gaze estimation using ARKit's TrueDepth camera.
//  This is an experimental feature (Issue #22) — opt-in, privacy-first.
//
//  Created for Ramadan Impact — exploratory research.
//

import Foundation
import Combine
import SwiftUI

#if canImport(ARKit) && canImport(UIKit)
import ARKit
import UIKit
#endif

// MARK: - Gaze Point

/// A single gaze sample in screen coordinates with a confidence score.
public struct GazePoint: Sendable, Equatable {
    /// The estimated gaze position in screen-space coordinates (points).
    public let screenPosition: CGPoint
    
    /// Confidence of the gaze estimate (0.0 – 1.0).
    /// Higher values indicate more reliable tracking.
    public let confidence: Float
    
    /// Timestamp of the sample.
    public let timestamp: TimeInterval
    
    public init(screenPosition: CGPoint, confidence: Float, timestamp: TimeInterval = CACurrentMediaTime()) {
        self.screenPosition = screenPosition
        self.confidence = min(1.0, max(0.0, confidence))
        self.timestamp = timestamp
    }
}

// MARK: - Tracking State

/// The operational state of the eye tracking system.
public enum EyeTrackingState: Sendable, Equatable {
    /// Not started or explicitly stopped.
    case inactive
    
    /// Initializing ARKit session.
    case initializing
    
    /// Actively tracking — the associated `GazePoint` is the latest sample.
    case tracking(GazePoint)
    
    /// The user's face / eyes are temporarily not visible.
    case faceLost
    
    /// Eye tracking is not available on this device.
    case unavailable(reason: String)
}

// MARK: - Eye Tracking Service

/// Manages ARKit-based eye tracking to estimate the user's gaze position
/// on screen. All data stays local and the service is opt-in only.
///
/// - Note: Requires iPhone X or later (TrueDepth camera).
///   Falls back to `.unavailable` on unsupported devices.
@MainActor
internal final class EyeTrackingService: NSObject, ObservableObject {
    
    // MARK: - Published State
    
    /// Current tracking state, observed by the UI.
    @Published public private(set) var state: EyeTrackingState = .inactive
    
    /// The most recent smoothed gaze point (nil when not tracking).
    @Published public private(set) var currentGaze: GazePoint?
    
    /// Whether ARKit face tracking is supported on this device.
    @Published public private(set) var isSupported: Bool = false
    
    // MARK: - Configuration
    
    /// Multiplier used to scale the gaze direction vector from the face lookAtPoint 
    /// to screen bounds, effectively controlling the tracking sensitivity based on user distance.
    /// Valid range: > 0
    public var gazeProjectionScale: Float = 8.0 {
        didSet {
            guard gazeProjectionScale > 0 else {
                gazeProjectionScale = oldValue
                assertionFailure("gazeProjectionScale must be greater than 0")
                return
            }
        }
    }
    
    /// Minimum confidence threshold — gaze samples below this are discarded.
    /// Valid range: 0.0...1.0
    public var minimumConfidence: Float = 0.3 {
        didSet {
            guard (0.0...1.0).contains(minimumConfidence) else {
                minimumConfidence = max(0.0, min(1.0, minimumConfidence))
                assertionFailure("minimumConfidence must be between 0.0 and 1.0 (clamped to valid range)")
                return
            }
        }
    }
    
    /// Smoothing factor for the Kalman-style filter (0 = no smoothing, 1 = full lag).
    /// A value around 0.7 works well for reading.
    /// Valid range: 0.0...1.0
    public var smoothingFactor: CGFloat = 0.7 {
        didSet {
            guard (0.0...1.0).contains(smoothingFactor) else {
                smoothingFactor = max(0.0, min(1.0, smoothingFactor))
                assertionFailure("smoothingFactor must be between 0.0 and 1.0 (clamped to valid range)")
                return
            }
        }
    }
    
    // MARK: - Private
    
#if canImport(ARKit) && canImport(UIKit) && !targetEnvironment(simulator)
    private var arSession: ARSession?
    private var isRunning = false
#endif
    
    /// Smoothed position accumulator.
    private var smoothedPosition: CGPoint = .zero
    private var hasInitialSample = false
    private var lastProcessedFrameTimestamp: TimeInterval?
    
    // MARK: - Lifecycle
    
    public override init() {
        super.init()
        checkAvailability()
    }
    
    // MARK: - Availability Check
    
    private func checkAvailability() {
#if canImport(ARKit) && canImport(UIKit) && !targetEnvironment(simulator)
        isSupported = ARFaceTrackingConfiguration.isSupported
#else
        isSupported = false
#endif
    }
    
    // MARK: - Start / Stop
    
    /// Begin eye tracking. Requires camera permission.
    public func startTracking() {
        guard state == .inactive || state == .faceLost else { return }
        
#if canImport(ARKit) && canImport(UIKit) && !targetEnvironment(simulator)
        guard ARFaceTrackingConfiguration.isSupported else {
            state = .unavailable(reason: String(localized: "This device does not support face tracking (TrueDepth camera required)."))
            AppLogger.shared.warn("Eye tracking unavailable: no TrueDepth camera", category: .ui)
            return
        }
        
        state = .initializing
        
        let configuration = ARFaceTrackingConfiguration()
        configuration.isLightEstimationEnabled = false  // Don't need it — saves battery
        
        let session = ARSession()
        session.delegate = self
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        
        arSession = session
        isRunning = true
        
        AppLogger.shared.info("Eye tracking started", category: .ui)
#else
        state = .unavailable(reason: String(localized: "Eye tracking requires iOS with TrueDepth camera."))
        AppLogger.shared.info("Eye tracking not available on this platform", category: .ui)
#endif
    }
    
    /// Stop eye tracking and release the AR session.
    public func stopTracking() {
#if canImport(ARKit) && canImport(UIKit) && !targetEnvironment(simulator)
        arSession?.pause()
        arSession = nil
        isRunning = false
#endif
        state = .inactive
        currentGaze = nil
        hasInitialSample = false
        AppLogger.shared.info("Eye tracking stopped", category: .ui)
    }
    
    // MARK: - Gaze Projection
    
    /// Projects a 3D look-at vector from the face anchor to a 2D screen point.
    ///
    /// The `lookAtPoint` from `ARFaceAnchor` gives us a direction vector
    /// in face-anchor space. We transform it to world space, then project
    /// onto the screen plane.
#if canImport(ARKit) && canImport(UIKit) && !targetEnvironment(simulator)
    private func projectGazeToScreen(faceAnchor: ARFaceAnchor, frame: ARFrame) -> GazePoint? {
        guard let screenSize = screenSize else { return nil }
        
        // The lookAtPoint is in face anchor coordinate space
        let lookAt = faceAnchor.lookAtPoint
        
        // Eye positions in face anchor space
        let leftEye = faceAnchor.leftEyeTransform
        let rightEye = faceAnchor.rightEyeTransform
        
        // Average eye position (midpoint between eyes)
        let eyeMidX = (leftEye.columns.3.x + rightEye.columns.3.x) / 2.0
        let eyeMidY = (leftEye.columns.3.y + rightEye.columns.3.y) / 2.0
        let eyeMidZ = (leftEye.columns.3.z + rightEye.columns.3.z) / 2.0
        
        // Gaze direction from the midpoint of the eyes
        let gazeDirectionX = lookAt.x - eyeMidX
        let gazeDirectionY = lookAt.y - eyeMidY
        let gazeDirectionZ = lookAt.z - eyeMidZ
        
        // Map gaze direction to screen coordinates
        // The face is typically ~30–50cm from the phone screen
        // lookAtPoint X ranges roughly from -0.05 to 0.05 for typical reading
        // lookAtPoint Y ranges roughly from -0.05 to 0.05
        
        // Normalize to screen space (inverted X because front camera is mirrored)
        let normalizedX = CGFloat(0.5 - gazeDirectionX * gazeProjectionScale)
        let normalizedY = CGFloat(0.5 - gazeDirectionY * gazeProjectionScale)
        
        // Clamp to screen bounds
        let screenX = min(screenSize.width, max(0, normalizedX * screenSize.width))
        let screenY = min(screenSize.height, max(0, normalizedY * screenSize.height))
        
        // Confidence based on how centered the gaze is and tracking quality
        let distFromCenter = sqrt(pow(gazeDirectionX, 2) + pow(gazeDirectionY, 2))
        let rawConfidence = max(0, 1.0 - distFromCenter * 5.0)
        let trackingConfidence = faceAnchor.isTracked ? rawConfidence : rawConfidence * 0.3
        
        return GazePoint(
            screenPosition: CGPoint(x: screenX, y: screenY),
            confidence: trackingConfidence
        )
    }
    
    private var screenSize: CGSize? {
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first else { return nil }
        return windowScene.screen.bounds.size
    }
#endif
    
    // MARK: - Smoothing
    
    /// Apply exponential moving average to reduce jitter.
    private func smoothGaze(_ raw: CGPoint) -> CGPoint {
        if !hasInitialSample {
            smoothedPosition = raw
            hasInitialSample = true
            return raw
        }
        
        let alpha = smoothingFactor
        smoothedPosition = CGPoint(
            x: alpha * smoothedPosition.x + (1 - alpha) * raw.x,
            y: alpha * smoothedPosition.y + (1 - alpha) * raw.y
        )
        return smoothedPosition
    }
}

// MARK: - ARSessionDelegate

#if canImport(ARKit) && canImport(UIKit) && !targetEnvironment(simulator)
extension EyeTrackingService: ARSessionDelegate {
    
    nonisolated public func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Process at ~15 FPS instead of 30 to save battery
        // We skip every other frame
        let frameTime = frame.timestamp
        
        Task { @MainActor in
            let shouldProcess: Bool
            if let lastTime = self.lastProcessedFrameTimestamp {
                shouldProcess = (frameTime - lastTime) >= (1.0 / 15.0)
            } else {
                shouldProcess = true
            }
            guard shouldProcess else { return }
            self.lastProcessedFrameTimestamp = frameTime
            
            guard let faceAnchor = frame.anchors.compactMap({ $0 as? ARFaceAnchor }).first else {
                if self.state != .faceLost && self.state != .inactive {
                    self.state = .faceLost
                }
                return
            }
            
            guard faceAnchor.isTracked else {
                self.state = .faceLost
                return
            }
            
            guard let rawGaze = self.projectGazeToScreen(faceAnchor: faceAnchor, frame: frame) else {
                return
            }
            
            // Filter low-confidence samples
            guard rawGaze.confidence >= self.minimumConfidence else {
                return
            }
            
            // Smooth the gaze position
            let smoothedPos = self.smoothGaze(rawGaze.screenPosition)
            let smoothedGaze = GazePoint(
                screenPosition: smoothedPos,
                confidence: rawGaze.confidence,
                timestamp: frameTime
            )
            
            self.currentGaze = smoothedGaze
            self.state = .tracking(smoothedGaze)
        }
    }
    
    nonisolated public func session(_ session: ARSession, didFailWithError error: Error) {
        Task { @MainActor in
            self.state = .unavailable(reason: error.localizedDescription)
            AppLogger.shared.error("AR session failed: \(error.localizedDescription)", category: .ui)
        }
    }
    
    nonisolated public func sessionWasInterrupted(_ session: ARSession) {
        Task { @MainActor in
            self.state = .faceLost
        }
    }
    
    nonisolated public func sessionInterruptionEnded(_ session: ARSession) {
        Task { @MainActor in
            // Session will resume automatically
            AppLogger.shared.info("AR session interruption ended", category: .ui)
        }
    }
}
#endif
