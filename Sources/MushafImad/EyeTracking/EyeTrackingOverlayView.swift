//
//  EyeTrackingOverlayView.swift
//  MushafImad
//
//  Debug / visualization overlay that shows the gaze point,
//  active verse info, and reading progress bar.
//
//  Created for Ramadan Impact — exploratory research (Issue #22).
//

import SwiftUI

/// A translucent overlay that visualizes eye-tracking data on top of the Mushaf page.
///
/// **Features:**
/// - Animated gaze dot that follows the estimated gaze position
/// - Active verse indicator showing chapter:verse
/// - Reading progress bar along the side
/// - Debug info panel (togglable)
///
/// This view is intended for development / research and can be toggled
/// via `EyeTrackingSettingsView`.
public struct EyeTrackingOverlayView: View {
    @ObservedObject var tracker: ReadingProgressTracker
    var currentGaze: GazePoint?
    var showDebugInfo: Bool
    var trackingState: EyeTrackingState
    
    @State private var gazeAnimationPosition: CGPoint = .zero
    @State private var pulseScale: CGFloat = 1.0
    
    public init(
        tracker: ReadingProgressTracker,
        currentGaze: GazePoint? = nil,
        showDebugInfo: Bool = false,
        trackingState: EyeTrackingState = .inactive
    ) {
        self.tracker = tracker
        self.currentGaze = currentGaze
        self.showDebugInfo = showDebugInfo
        self.trackingState = trackingState
    }
    
    public var body: some View {
        ZStack {
            // Gaze dot
            if let gaze = currentGaze {
                gazeDot(at: gaze)
            }
            
            // Reading progress bar (right side for RTL)
            progressBar
            
            // Active verse indicator
            if let verse = tracker.activeVerse {
                activeVerseIndicator(verse: verse)
            }
            
            // Status indicator
            statusBadge
            
            // Debug panel
            if showDebugInfo {
                debugPanel
            }
        }
        .allowsHitTesting(false) // Passthrough all touches
        .onChange(of: currentGaze?.screenPosition) { _, newPos in
            if let pos = newPos {
                withAnimation(.interpolatingSpring(stiffness: 80, damping: 12)) {
                    gazeAnimationPosition = pos
                }
            }
        }
    }
    
    // MARK: - Gaze Dot
    
    @ViewBuilder
    private func gazeDot(at gaze: GazePoint) -> some View {
        let size: CGFloat = 24
        let confidence = CGFloat(gaze.confidence)
        
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        Color.green.opacity(0.8 * confidence),
                        Color.green.opacity(0.2 * confidence)
                    ],
                    center: .center,
                    startRadius: 2,
                    endRadius: size / 2
                )
            )
            .frame(width: size, height: size)
            .overlay(
                Circle()
                    .stroke(Color.green.opacity(0.6 * confidence), lineWidth: 2)
                    .scaleEffect(pulseScale)
            )
            .position(gazeAnimationPosition)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                    pulseScale = 1.4
                }
            }
            .onDisappear {
                withAnimation {
                    pulseScale = 1.0
                }
            }
    }
    
    // MARK: - Progress Bar
    
    private var progressBar: some View {
        GeometryReader { geometry in
            VStack {
                Spacer()
                    .frame(height: geometry.size.height * 0.1)
                
                // Vertical progress bar on the leading edge (right side in RTL)
                ZStack(alignment: .top) {
                    // Track
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.gray.opacity(0.2))
                        .frame(width: 6, height: geometry.size.height * 0.8)
                    
                    // Fill
                    RoundedRectangle(cornerRadius: 3)
                        .fill(
                            LinearGradient(
                                colors: [Color.green, Color.blue],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(
                            width: 6,
                            height: geometry.size.height * 0.8 * tracker.readingProgress
                        )
                        .animation(.easeInOut(duration: 0.3), value: tracker.readingProgress)
                }
                
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 4)
        }
    }
    
    // MARK: - Active Verse Indicator
    
    @ViewBuilder
    private func activeVerseIndicator(verse: Verse) -> some View {
        VStack {
            Spacer()
            
            HStack(spacing: 8) {
                Image(systemName: "eye.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.green)
                
                Text("\(verse.chapterNumber):\(verse.number)")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.primary)
                
                Spacer()
                
                Text("\(Int(tracker.readingProgress * 100))%")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
        .animation(.spring(response: 0.3), value: verse.verseID)
    }
    
    // MARK: - Status Badge
    
    private var statusBadge: some View {
        VStack {
            HStack {
                Spacer()
                
                HStack(spacing: 4) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    
                    Text(statusText)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
            }
            .padding(.trailing, 12)
            .padding(.top, 8)
            
            Spacer()
        }
    }
    
    private var statusColor: Color {
        switch trackingState {
        case .tracking: return .green
        case .initializing: return .yellow
        case .faceLost: return .orange
        case .inactive: return .gray
        case .unavailable: return .red
        }
    }
    
    private var statusText: String {
        switch trackingState {
        case .tracking: return String(localized: "Tracking")
        case .initializing: return String(localized: "Starting…")
        case .faceLost: return String(localized: "Face lost")
        case .inactive: return String(localized: "Inactive")
        case .unavailable: return String(localized: "Unavailable")
        }
    }
    
    // MARK: - Debug Panel
    
    private var debugPanel: some View {
        VStack {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("👁️ Eye Tracking Debug")
                        .font(.system(size: 11, weight: .bold))
                    
                    if let gaze = currentGaze {
                        Text("Position: (\(Int(gaze.screenPosition.x)), \(Int(gaze.screenPosition.y)))")
                            .font(.system(size: 10, design: .monospaced))
                        Text("Confidence: \(String(format: "%.2f", gaze.confidence))")
                            .font(.system(size: 10, design: .monospaced))
                    }
                    
                    Text("Line: \(tracker.activeLineIndex) / \(GazeToVerseMapper.linesPerPage - 1)")
                        .font(.system(size: 10, design: .monospaced))
                    
                    if let verse = tracker.activeVerse {
                        Text("Verse: \(verse.chapterNumber):\(verse.number)")
                            .font(.system(size: 10, design: .monospaced))
                    }
                    
                    Text("Progress: \(String(format: "%.0f", tracker.readingProgress * 100))%")
                        .font(.system(size: 10, design: .monospaced))
                    
                    Text("Page done: \(tracker.pageCompleted ? "✅" : "❌")")
                        .font(.system(size: 10, design: .monospaced))
                }
                .foregroundStyle(.primary)
                .padding(8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                
                Spacer()
            }
            .padding(.leading, 12)
            .padding(.top, 60)
            
            Spacer()
        }
    }
}
