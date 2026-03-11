//
//  ReadingSession.swift
//  MushafImad
//
//  SwiftData model to persist eye-tracking reading progress.
//
//  Created for Ramadan Impact — exploratory research (Issue #22).
//

import Foundation
import SwiftData

/// Records a reading session detected via eye tracking or heuristic estimation.
/// Persisted locally via SwiftData for reading progress and resumption.
@Model
public final class ReadingSession {
    @Attribute(.unique) public var id: UUID
    
    /// The page number where this session was recorded (1–604).
    public var pageNumber: Int
    
    /// The last verse ID the user was reading when the session ended.
    public var lastVerseID: Int
    
    /// The verse's chapter number for quick display.
    public var chapterNumber: Int
    
    /// The verse number within its chapter.
    public var verseNumber: Int
    
    /// The line index (0–14) where the user's gaze last rested.
    public var lastLineIndex: Int
    
    /// When this reading session started.
    public var startedAt: Date
    
    /// When this reading session was last updated (the user's gaze was last tracked).
    public var lastUpdatedAt: Date
    
    /// Total active reading time in seconds (excluding pauses / face-lost).
    public var activeReadingDuration: TimeInterval
    
    /// The method used for tracking.
    public var trackingMethod: TrackingMethod
    
    /// Whether the user reached the end of the page naturally.
    public var completedPage: Bool
    
    /// Average gaze confidence during this session (0.0–1.0).
    public var averageConfidence: Float
    
    public init(
        id: UUID = UUID(),
        pageNumber: Int,
        lastVerseID: Int,
        chapterNumber: Int,
        verseNumber: Int,
        lastLineIndex: Int = 0,
        startedAt: Date = .now,
        lastUpdatedAt: Date = .now,
        activeReadingDuration: TimeInterval = 0,
        trackingMethod: TrackingMethod = .eyeTracking,
        completedPage: Bool = false,
        averageConfidence: Float = 0
    ) {
        self.id = id
        self.pageNumber = pageNumber
        self.lastVerseID = lastVerseID
        self.chapterNumber = chapterNumber
        self.verseNumber = verseNumber
        self.lastLineIndex = lastLineIndex
        self.startedAt = startedAt
        self.lastUpdatedAt = lastUpdatedAt
        self.activeReadingDuration = activeReadingDuration
        self.trackingMethod = trackingMethod
        self.completedPage = completedPage
        self.averageConfidence = averageConfidence
    }
}

/// The method used to track reading progress.
public enum TrackingMethod: String, Codable {
    /// Hardware eye tracking via ARKit TrueDepth camera.
    case eyeTracking
    
    /// Heuristic-based estimation (scroll position + reading speed).
    case heuristic
    
    /// Manual bookmark by the user.
    case manual
}
