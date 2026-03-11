//
//  EyeTrackingCoordinator.swift
//  MushafImad
//
//  Ties together the EyeTrackingService, FallbackGazeEstimator,
//  GazeToVerseMapper, and ReadingProgressTracker into a single
//  coordinator that MushafView can consume.
//
//  Created for Ramadan Impact — exploratory research (Issue #22).
//

import Foundation
import SwiftUI
import Combine

/// Coordinates all eye-tracking subsystems and provides a single
/// integration point for `MushafView`.
///
/// Usage:
/// ```swift
/// @StateObject private var eyeCoordinator = EyeTrackingCoordinator()
/// // In your view body:
/// .onAppear { eyeCoordinator.activate(pageNumber: 1, verses: [...], pageFrame: ...) }
/// .onDisappear { eyeCoordinator.deactivate() }
/// ```
@MainActor
public final class EyeTrackingCoordinator: ObservableObject {
    
    // MARK: - Sub-services (public for settings binding)
    
    public let eyeTrackingService = EyeTrackingService()
    public let fallbackEstimator = FallbackGazeEstimator()
    public let progressTracker = ReadingProgressTracker()
    
    // MARK: - Published State
    
    /// The verse currently being read (auto-highlighted).
    @Published public var gazeHighlightedVerse: Verse?
    
    /// Current gaze point for overlay rendering.
    @Published public var currentGaze: GazePoint?
    
    /// Overall tracking state.
    @Published public var trackingState: EyeTrackingState = .inactive
    
    /// Whether the feature is enabled by the user.
    @AppStorage("eye_tracking_enabled") public var isEnabled: Bool = false
    @AppStorage("eye_tracking_auto_highlight") private var autoHighlight: Bool = true
    @AppStorage("eye_tracking_auto_advance") private var autoAdvance: Bool = false
    @AppStorage("eye_tracking_show_overlay") public var showOverlay: Bool = false
    @AppStorage("eye_tracking_show_debug") public var showDebugInfo: Bool = false
    @AppStorage("eye_tracking_dwell_time") private var dwellTime: Double = 1.5
    @AppStorage("eye_tracking_reading_speed") private var readingSpeed: Double = 80
    @AppStorage("eye_tracking_use_fallback") private var useFallbackMode: Bool = false
    
    // MARK: - Private
    
    private var cancellables = Set<AnyCancellable>()
    private var gazeUpdateTimer: Timer?
    
    // MARK: - Init
    
    public init() {
        setupBindings()
    }
    
    // MARK: - Bindings
    
    private func setupBindings() {
        // Forward active verse changes
        progressTracker.onActiveVerseChanged = { [weak self] verse in
            guard let self else { return }
            if self.autoHighlight {
                self.gazeHighlightedVerse = verse
            }
        }
        
        // Observe eye tracking service state
        eyeTrackingService.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.trackingState = state
            }
            .store(in: &cancellables)
        
        // Forward gaze from eye tracking service
        eyeTrackingService.$currentGaze
            .receive(on: DispatchQueue.main)
            .compactMap { $0 }
            .sink { [weak self] gaze in
                guard let self else { return }
                self.currentGaze = gaze
                self.progressTracker.processGazePoint(gaze)
            }
            .store(in: &cancellables)
        
        // Forward gaze from fallback estimator
        fallbackEstimator.$estimatedGaze
            .receive(on: DispatchQueue.main)
            .compactMap { $0 }
            .sink { [weak self] gaze in
                guard let self else { return }
                // Only use fallback when eye tracking is not active
                guard !self.eyeTrackingService.isSupported || self.useFallbackMode else { return }
                self.currentGaze = gaze
                self.progressTracker.processGazePoint(gaze)
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Lifecycle
    
    /// Activate tracking for a specific page.
    ///
    /// - Parameters:
    ///   - pageNumber: The Mushaf page number (1–604).
    ///   - verses: The verses on the current page.
    ///   - pageFrame: The on-screen frame of the page content area.
    ///   - onPageCompleted: Callback when the tracker detects page completion.
    public func activate(
        pageNumber: Int,
        verses: [Verse],
        pageFrame: CGRect,
        onPageCompleted: (() -> Void)? = nil
    ) {
        guard isEnabled else { return }
        
        // Configure the progress tracker
        progressTracker.dwellTimeThreshold = dwellTime
        progressTracker.autoAdvanceEnabled = autoAdvance
        progressTracker.onPageCompleted = onPageCompleted
        
        // Start tracking
        progressTracker.startTracking(
            pageNumber: pageNumber,
            verses: verses,
            pageFrame: pageFrame
        )
        
        // Start the appropriate gaze source
        if eyeTrackingService.isSupported && !useFallbackMode {
            eyeTrackingService.startTracking()
        } else if useFallbackMode || !eyeTrackingService.isSupported {
            fallbackEstimator.arabicWordsPerMinute = readingSpeed
            fallbackEstimator.startForPage(pageFrame: pageFrame)
            trackingState = .tracking(GazePoint(screenPosition: .zero, confidence: 0.5))
        }
        
        AppLogger.shared.info("Eye tracking coordinator activated for page \(pageNumber)", category: .ui)
    }
    
    /// Deactivate all tracking.
    public func deactivate() {
        eyeTrackingService.stopTracking()
        fallbackEstimator.stopEstimating()
        progressTracker.stopTracking()
        gazeHighlightedVerse = nil
        currentGaze = nil
        trackingState = .inactive
    }
    
    /// Update geometry after layout changes.
    public func updateGeometry(frame: CGRect) {
        progressTracker.updateGeometry(frame: frame)
    }
    
    /// Pause tracking (app backgrounded, sheet presented, etc.).
    public func pause() {
        fallbackEstimator.pause()
    }
    
    /// Resume tracking after a pause.
    public func resume() {
        fallbackEstimator.resume()
    }
}
