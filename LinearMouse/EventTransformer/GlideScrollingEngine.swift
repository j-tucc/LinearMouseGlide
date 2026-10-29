// MIT License
// Copyright (c) 2021-2026 LinearMouse

import CoreVideo
import Defaults
import Foundation
import os.log

/// A port of Mouse Glide 1.2.15's scroll engine.
///
/// Each wheel event adds `speed × max(|pointDelta|, 26)` points to a target,
/// and every display frame emits 13.36% of the remaining distance as a
/// continuous scroll event, until a frame would move 1 point or less.
///
/// Unlike the original, frames are posted with `CGEvent.post` at the same tap
/// location instead of re-using the tap proxy off the tap thread (which
/// crashed Mouse Glide), and every frame posts a fresh copy rather than
/// re-posting one shared event.
final class GlideScrollingEngine {
    static let shared = GlideScrollingEngine()

    private static let log = OSLog(subsystem: Bundle.main.bundleIdentifier!, category: "GlideScrollingEngine")

    /// Fraction of the remaining distance emitted per display frame.
    static let easing = 0.1336
    /// Smallest distance, in points, a single wheel event glides.
    static let minimumDelta = 26.0
    /// Gliding stops once a frame would move this many points or fewer.
    static let stopThreshold = 1.0

    private var lock = os_unfair_lock()
    private var displayLink: CVDisplayLink?
    private var template: CGEvent?
    private var horizontal = false
    private var position = 0.0
    private var target = 0.0
    private var lastDelta = 0.0
    private var enabled = Defaults[.glideEnabled]

    /// Frames are copies of events already addressed by the window server,
    /// re-entering where they were captured, so they keep their target and
    /// never move the cursor.
    var post: (CGEvent) -> Void = { $0.post(tap: .cgAnnotatedSessionEventTap) }

    init() {
        Defaults.observe(.glideEnabled, options: []) { [weak self] change in
            self?.setEnabled(change.newValue)
        }
        .tieToLifetime(of: self)
    }

    var isEnabled: Bool {
        withLock { enabled }
    }

    private func setEnabled(_ newValue: Bool) {
        withLock { enabled = newValue }
        if !newValue {
            stop()
        }
    }

    /// Returns true when the event was consumed and will be replayed as a glide.
    /// `leftMultiplier` scales leftward horizontal wheel input only.
    func feed(_ event: CGEvent, speed: Double, reverse: Bool, leftMultiplier: Double = 1) -> Bool {
        // Trackpads and Magic Mouse already scroll smoothly.
        guard event.getIntegerValueField(.scrollWheelEventScrollPhase) == 0,
              event.getIntegerValueField(.scrollWheelEventMomentumPhase) == 0,
              event.getIntegerValueField(.scrollWheelEventScrollCount) == 0 else {
            return false
        }

        var delta = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
        var lineField = CGEventField.scrollWheelEventDeltaAxis1
        var isHorizontalInput = false
        if delta == 0 {
            delta = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
            lineField = .scrollWheelEventDeltaAxis2
            isHorizontalInput = true
        }
        guard delta != 0, let copy = event.copy() else {
            return false
        }
        // Side wheels report left as negative.
        let scale = isHorizontalInput && delta < 0 ? leftMultiplier : 1

        if reverse {
            delta = -delta
            copy.setIntegerValueField(lineField, value: -copy.getIntegerValueField(lineField))
        }
        let clamped = delta > 0 ? max(delta, Self.minimumDelta) : min(delta, -Self.minimumDelta)

        withLock {
            template = copy
            // Shift turns a vertical wheel sideways, as in the original. Unlike
            // the original, horizontal wheels (tilt or side wheels) also glide
            // sideways instead of being redirected vertically.
            horizontal = isHorizontalInput || event.flags.contains(.maskShift)
            if clamped * lastDelta <= 0 {
                target = speed * scale * clamped
                position = 0
            } else {
                target += speed * scale * clamped
            }
            lastDelta = clamped
        }

        start()
        return true
    }

    func stop() {
        if let displayLink {
            CVDisplayLinkStop(displayLink)
        }
        reset()
    }

    private func reset() {
        withLock {
            template = nil
            position = 0
            target = 0
            lastDelta = 0
        }
    }

    private func start() {
        if displayLink == nil {
            var link: CVDisplayLink?
            guard CVDisplayLinkCreateWithActiveCGDisplays(&link) == kCVReturnSuccess, let link else {
                os_log("Failed to create display link", log: Self.log, type: .error)
                return
            }
            CVDisplayLinkSetOutputCallback(link, { _, _, _, _, _, context in
                Unmanaged<GlideScrollingEngine>.fromOpaque(context!).takeUnretainedValue().tick()
                return kCVReturnSuccess
            }, Unmanaged.passUnretained(self).toOpaque())
            displayLink = link
        }

        if let displayLink, !CVDisplayLinkIsRunning(displayLink) {
            CVDisplayLinkStart(displayLink)
        }
    }

    /// Runs on the display link thread.
    private func tick() {
        let (step, template, horizontal) = withLock { () -> (Double, CGEvent?, Bool) in
            let step = (target - position) * Self.easing
            let template = self.template
            if abs(step) <= Self.stopThreshold {
                // Reset under the lock so input arriving now starts a fresh glide.
                self.template = nil
                position = 0
                target = 0
                lastDelta = 0
            } else {
                position += step
            }
            return (step, template, self.horizontal)
        }

        if let event = template?.copy() {
            event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: horizontal ? 0 : step)
            event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: horizontal ? step : 0)
            event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 0)
            event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: 0)
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            event.isLinearMouseSyntheticEvent = true
            post(event)
        }

        if abs(step) <= Self.stopThreshold, let displayLink {
            CVDisplayLinkStop(displayLink)
            if withLock({ self.template != nil }) {
                CVDisplayLinkStart(displayLink)
            }
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return body()
    }
}
