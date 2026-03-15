//
//  FallbackGazeEstimator.swift
//  MushafImad
//
//  Scroll-position and dwell-time based reading position estimator.
//  Used when eye tracking is unavailable (macOS, older iPhones, simulators).
//
//  Created for Ramadan Impact — exploratory research (Issue #22).
//

import Foundation
import SwiftUI
import Combine

/// Estimates the user's reading position using heuristic methods
/// when hardware eye tracking is not available.
///
/// ## Strategy
/// 1. When the user lands on a page, start a timer.
/// 2. Estimate reading progress line-by-line based on configurable reading speed.
/// 3. Account for pauses (app backgrounding, user interaction) by freezing the timer.
/// 4. Publish estimated gaze points that the `ReadingProgressTracker` can consume.
@MainActor
internal final class FallbackGazeEstimator: ObservableObject {
    
    // MARK: - Published
    
    /// The estimated gaze point from heuristics.
    @Published public private(set) var estimatedGaze: GazePoint?
    
    /// Whether the estimator is actively running.
    @Published public private(set) var isActive: Bool = false
    
    // MARK: - Configuration
    
    /// Average Arabic reading speed in words per minute.
    /// Quran reading tends to be slower due to tajweed rules.
    /// Typical range: 50–120 WPM for careful Arabic reading.
    /// Valid range: > 0
    public var arabicWordsPerMinute: Double = 80 {
        didSet {
            guard arabicWordsPerMinute > 0 else {
                arabicWordsPerMinute = oldValue
                assertionFailure("arabicWordsPerMinute must be greater than 0")
                return
            }
            recalculateRate()
        }
    }
    
    /// Approximate number of words per line in the Mushaf.
    /// Standard Hafs 1441 layout has roughly 8–12 words per line.
    /// Valid range: > 0
    public var wordsPerLine: Double = 10 {
        didSet {
            guard wordsPerLine > 0 else {
                wordsPerLine = oldValue
                assertionFailure("wordsPerLine must be greater than 0")
                return
            }
        }
    }
    
    /// Number of lines per page.
    public let linesPerPage: Int = 15
    
    // MARK: - Private
    
    private var pageStartTime: Date?
    private var pausedDuration: TimeInterval = 0
    private var pauseStart: Date?
    private var updateTimer: Timer?
    private var currentPageFrame: CGRect = .zero
    
    /// Seconds per line, derived from reading speed.
    private var secondsPerLine: TimeInterval = 0
    
    // MARK: - Init
    
    public init() {
        recalculateRate()
    }
    
    // MARK: - Public API
    
    /// Start estimating reading progress for a new page.
    ///
    /// - Parameter pageFrame: The on-screen frame of the page content area.
    public func startForPage(pageFrame: CGRect) {
        stopEstimating()
        
        currentPageFrame = pageFrame
        pageStartTime = Date()
        pausedDuration = 0
        isActive = true
        
        // Update estimated position at ~4 Hz (enough for smooth progress)
        let timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.updateEstimatedGaze()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        updateTimer = timer
        
        AppLogger.shared.debug("Fallback gaze estimator started", category: .ui)
    }
    
    /// Stop the estimator (e.g., when navigating away from the page).
    public func stopEstimating() {
        updateTimer?.invalidate()
        updateTimer = nil
        isActive = false
        estimatedGaze = nil
        pageStartTime = nil
        pausedDuration = 0
        pauseStart = nil
    }
    
    /// Pause estimation (e.g., when the app goes to background or a sheet is presented).
    public func pause() {
        guard pauseStart == nil else { return }
        pauseStart = Date()
    }
    
    /// Resume estimation after a pause.
    public func resume() {
        if let start = pauseStart {
            pausedDuration += Date().timeIntervalSince(start)
            pauseStart = nil
        }
    }
    
    /// Reset the timer for the current page (e.g., user scrolled back to top).
    public func resetPageTimer() {
        pageStartTime = Date()
        pausedDuration = 0
    }
    
    /// Update geometry manually if it changes during active estimation
    public func updateGeometry(frame: CGRect) {
        currentPageFrame = frame
    }
    
    // MARK: - Internal
    
    private func recalculateRate() {
        let wordsPerSecond = arabicWordsPerMinute / 60.0
        secondsPerLine = wordsPerLine / wordsPerSecond
    }
    
    private func updateEstimatedGaze() {
        guard let startTime = pageStartTime, isActive else { return }
        guard currentPageFrame.width > 0 else { return }
        
        // Calculate effective reading time (excluding pauses)
        var elapsed = Date().timeIntervalSince(startTime) - pausedDuration
        if let pauseStart {
            elapsed -= Date().timeIntervalSince(pauseStart)
        }
        elapsed = max(0, elapsed)
        
        // Determine current estimated line
        let estimatedLine = min(
            linesPerPage - 1,
            Int(elapsed / secondsPerLine)
        )
        
        // Determine progress within the line (0.0 – 1.0)
        let lineElapsed = elapsed - Double(estimatedLine) * secondsPerLine
        let lineProgress = min(1.0, lineElapsed / secondsPerLine)
        
        // Convert to screen coordinates
        // Reading direction is RTL, so X goes from right to left
        let lineHeight = currentPageFrame.height / CGFloat(linesPerPage)
        let headerOffset: CGFloat = 40  // Approximate header height
        
        let screenY = currentPageFrame.minY + headerOffset + (CGFloat(estimatedLine) + 0.5) * lineHeight
        // RTL: start from right side and move left
        let screenX = currentPageFrame.maxX - CGFloat(lineProgress) * currentPageFrame.width
        
        // Confidence decreases slightly over time (user might have paused reading)
        let timeConfidence = max(0.3, 1.0 - Float(elapsed / (secondsPerLine * Double(linesPerPage) * 2.0)))
        
        let gaze = GazePoint(
            screenPosition: CGPoint(x: screenX, y: screenY),
            confidence: timeConfidence
        )
        
        estimatedGaze = gaze
    }
}
