//
//  GazeToVerseMapper.swift
//  MushafImad
//
//  Maps screen-space gaze coordinates to Mushaf lines and verses
//  using the page layout metadata (VerseHighlight bounds).
//
//  Created for Ramadan Impact — exploratory research (Issue #22).
//

import Foundation
import SwiftUI

// MARK: - Mapped Gaze Result

/// The result of mapping a gaze point to a specific location in the Mushaf.
public struct MappedGazeResult: Equatable, Sendable {
    /// The line index (0–14) that the gaze falls on.
    public let lineIndex: Int
    
    /// The verse that the gaze is closest to on this line (nil if no verse occupies this region).
    public let verse: Verse?
    
    /// The verse's identifier — useful for quick equality checks.
    public let verseID: Int?
    
    /// Confidence of the mapping (inherits from gaze + geometric proximity).
    public let confidence: Float
    
    /// The normalized position within the line (0 = top of line, 1 = bottom).
    public let lineProgress: CGFloat
    
    public static func == (lhs: MappedGazeResult, rhs: MappedGazeResult) -> Bool {
        lhs.lineIndex == rhs.lineIndex && lhs.verseID == rhs.verseID
    }
}

// MARK: - Gaze Mapper

/// Maps screen-space gaze coordinates to Mushaf page elements (lines and verses).
///
/// The Mushaf page layout consists of:
/// - 15 lines per page (indices 0–14)
/// - Each line has a fixed aspect ratio (1440:232)
/// - Verses have `VerseHighlight` objects with `left`, `right`, and `line` properties
///   that define their bounding region on the page
///
/// This mapper uses the page's geometry to determine which line and verse
/// the user is looking at.
@MainActor
public final class GazeToVerseMapper: ObservableObject {
    
    // MARK: - Configuration
    
    /// The total number of lines per Mushaf page.
    public static let linesPerPage = 15
    
    /// Original line image dimensions.
    private static let originalLineWidth: CGFloat = 1440
    private static let originalLineHeight: CGFloat = 232
    
    // MARK: - Page Geometry Cache
    
    /// Cached geometry for the current page, set when the page view measures itself.
    private var pageFrame: CGRect = .zero
    private var headerHeight: CGFloat = 0
    private var lineHeight: CGFloat = 0
    
    // MARK: - Public API
    
    /// Update the mapper with the current page's on-screen geometry.
    ///
    /// Call this whenever the page layout changes (rotation, page flip, etc.)
    ///
    /// - Parameters:
    ///   - frame: The on-screen frame of the page content area (excluding chrome).
    ///   - headerOffset: The height of the page header above the lines.
    public func updatePageGeometry(frame: CGRect, headerOffset: CGFloat = 40) {
        self.pageFrame = frame
        self.headerHeight = headerOffset
        
        // Each line occupies an equal fraction of the remaining height
        let availableWidth = frame.width
        let calculatedLineHeight = availableWidth / Self.originalLineWidth * Self.originalLineHeight
        self.lineHeight = calculatedLineHeight * 0.73  // Match the 0.73 factor from QuranPageView
    }
    
    /// Map a screen-space gaze point to a line and verse on the current page.
    ///
    /// - Parameters:
    ///   - gazePoint: The estimated gaze position in screen coordinates.
    ///   - verses: The verses on the current page (from `Page.verses1441`).
    /// - Returns: A `MappedGazeResult` if the gaze falls within the page area, nil otherwise.
    public func mapGazeToVerse(
        gazePoint: GazePoint,
        verses: [Verse]
    ) -> MappedGazeResult? {
        let screenPos = gazePoint.screenPosition
        
        // Check if gaze is within the page frame
        guard pageFrame.contains(screenPos) else {
            return nil
        }
        
        // Convert screen position to page-relative position
        let relativeY = screenPos.y - pageFrame.minY - headerHeight
        let relativeX = screenPos.x - pageFrame.minX
        
        // Determine which line the gaze falls on
        guard lineHeight > 0 else { return nil }
        let lineIndex = Int(relativeY / lineHeight)
        
        // Clamp to valid line range
        let clampedLine = min(Self.linesPerPage - 1, max(0, lineIndex))
        
        // Progress within the line (0 = top, 1 = bottom)
        let lineProgress = (relativeY - CGFloat(clampedLine) * lineHeight) / lineHeight
        let clampedProgress = min(1.0, max(0.0, lineProgress))
        
        // Find the verse at this position
        // The page is RTL, so we need to account for that
        let normalizedX = relativeX / pageFrame.width
        
        // Find the verse whose highlight region on this line contains the gaze X position
        let matchedVerse = findVerseAtPosition(
            normalizedX: Float(normalizedX),
            lineIndex: clampedLine,
            verses: verses
        )
        
        return MappedGazeResult(
            lineIndex: clampedLine,
            verse: matchedVerse,
            verseID: matchedVerse?.verseID,
            confidence: gazePoint.confidence,
            lineProgress: clampedProgress
        )
    }
    
    /// Estimate the current line based on scroll offset (for fallback mode).
    ///
    /// When eye tracking is unavailable, this provides a rough estimate
    /// based on time and reading speed.
    ///
    /// - Parameters:
    ///   - elapsedSeconds: Time the user has been on this page.
    ///   - wordsPerMinute: Estimated reading speed for Arabic text.
    ///   - totalWordsOnPage: Approximate word count for the page.
    /// - Returns: Estimated line index (0–14).
    public func estimateLineFromReadingTime(
        elapsedSeconds: TimeInterval,
        wordsPerMinute: Double = 80,
        totalWordsOnPage: Int = 150
    ) -> Int {
        let wordsPerSecond = wordsPerMinute / 60.0
        let wordsRead = wordsPerSecond * elapsedSeconds
        let fractionRead = wordsRead / Double(totalWordsOnPage)
        let estimatedLine = Int(fractionRead * Double(Self.linesPerPage))
        return min(Self.linesPerPage - 1, max(0, estimatedLine))
    }
    
    // MARK: - Private Helpers
    
    /// Find the verse whose highlight region contains the given normalized X position
    /// on the specified line.
    private func findVerseAtPosition(
        normalizedX: Float,
        lineIndex: Int,
        verses: [Verse]
    ) -> Verse? {
        // The highlight coordinates use RTL layout:
        // `left` and `right` are normalized positions where right > left
        // In RTL, the visual left corresponds to (1 - right) and visual right to (1 - left)
        
        var bestMatch: Verse?
        var smallestDistance: Float = .greatestFiniteMagnitude
        
        for verse in verses {
            let highlights = verse.highlights1441.filter { $0.line == lineIndex }
            
            for highlight in highlights {
                // Convert to visual coordinates (RTL)
                let visualLeft = 1.0 - highlight.right
                let visualRight = 1.0 - highlight.left
                
                // Check if the gaze X falls within this highlight's bounds
                if normalizedX >= visualLeft && normalizedX <= visualRight {
                    // Direct hit
                    return verse
                }
                
                // Track closest verse in case no direct hit
                let centerX = (visualLeft + visualRight) / 2.0
                let distance = abs(normalizedX - centerX)
                if distance < smallestDistance {
                    smallestDistance = distance
                    bestMatch = verse
                }
            }
        }
        
        // If we're within a reasonable distance (< 10% of page width), return nearest
        if smallestDistance < 0.1 {
            return bestMatch
        }
        
        return nil
    }
}
