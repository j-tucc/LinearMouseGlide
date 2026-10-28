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
/// Unlike the original, frames are posted with `CGEvent.post` instead of
/// re-using the tap proxy off the tap thread (which crashed Mouse Glide), and
/// every frame posts a fresh copy rather than re-posting one shared event.
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

    var post: (CGEvent) -> Void = { $0.post(tap: .cgSessionEventTap) }

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
    func feed(_ event: CGEvent, speed: Double, reverse: Bool) -> Bool {
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

        if reverse {
            delta = -delta
            copy.setIntegerValueField(lineField, value: -copy.getIntegerValueField(lineField))
        }
        let clamped = delta > 0 ? max(delta, Self.minimumDelta) : min(delta, -Self.minimumDelta)

        withLock {
            template = copy
            // A shifted vertical wheel scrolls horizontally, as in the original.
            horizontal = isHorizontalInput || event.flags.contains(.maskShift)
            if clamped * lastDelta <= 0 {
                target = speed * clamped
                position = 0
            } else {
                target += speed * clamped
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
            // The template still holds the cursor position of the wheel event;
            // posting that would snap the cursor back every frame.
            if let location = CGEvent(source: nil)?.location {
                event.location = location
            }
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

final class GlideScrollingTransformer: EventTransformer {
    private let glide: Scheme.Scrolling.Glide
    private let engine: GlideScrollingEngine

    init(glide: Scheme.Scrolling.Glide, engine: GlideScrollingEngine = .shared) {
        self.glide = glide
        self.engine = engine
    }

    var handlesPointerMotion: Bool {
        false
    }

    func transform(_ event: CGEvent, in _: EventTransformerContext) -> CGEvent? {
        guard event.type == .scrollWheel,
              !event.isLinearMouseSyntheticEvent,
              engine.isEnabled else {
            return event
        }

        return engine.feed(event, speed: glide.resolvedSpeed, reverse: glide.isReversed) ? nil : event
    }
}
