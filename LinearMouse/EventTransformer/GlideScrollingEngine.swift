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
///
/// It also fails open: a wheel event is only swallowed when frames can replay
/// it. If no frame follows within `stallTimeout`, the remaining distance is
/// delivered at once; repeated stalls switch to passing wheel events through
/// unsmoothed, probing every `bypassRetryInterval` until frames come back.
final class GlideScrollingEngine {
    static let shared = GlideScrollingEngine()

    private static let log = OSLog(subsystem: Bundle.main.bundleIdentifier!, category: "GlideScrollingEngine")

    /// Fraction of the remaining distance emitted per display frame.
    static let easing = 0.1336
    /// Smallest distance, in points, a single wheel event glides.
    static let minimumDelta = 26.0
    /// Gliding stops once a frame would move this many points or fewer.
    static let stopThreshold = 1.0

    /// A glide with no frame for this long is flushed and its frame source rebuilt.
    static let stallTimeout: TimeInterval = 0.15
    /// This many stalls within `stallWindow` switch to passing events through.
    static let stallsBeforeBypass = 2
    static let stallWindow: TimeInterval = 30
    /// While passing through, one wheel event this often probes for frames.
    static let bypassRetryInterval: TimeInterval = 5

    private var lock = os_unfair_lock()
    private var template: CGEvent?
    private var horizontal = false
    private var position = 0.0
    private var target = 0.0
    private var lastDelta = 0.0
    private var enabled = Defaults[.glideEnabled]
    private var lastTickAt: UInt64 = 0
    private var stallTimes: [UInt64] = []
    private var bypassing = false
    private var bypassRetryAt: UInt64 = 0

    /// Guards only the display link reference; never held while starting or
    /// stopping it, since stopping waits for an in-flight frame callback.
    private var linkLock = os_unfair_lock()
    private var displayLink: CVDisplayLink?

    private let watchdogQueue = DispatchQueue(label: "app.linearmouseglide.glide-watchdog", qos: .userInteractive)

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
        guard delta != 0 else {
            return false
        }

        let now = Self.now()
        let passThrough = withLock { () -> Bool in
            guard bypassing else {
                return false
            }
            guard now >= bypassRetryAt else {
                return true
            }
            // Let this one event probe whether frames are back.
            bypassRetryAt = now + Self.nanoseconds(Self.bypassRetryInterval)
            return false
        }
        guard !passThrough else {
            return false
        }

        // Only swallow the event once frames can replay it.
        guard startDisplayLink() else {
            enterBypass(reason: NSLocalizedString("Glide couldn't start its display timer.", comment: ""))
            return false
        }
        guard let copy = event.copy() else {
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

        watchdogQueue.asyncAfter(deadline: .now() + Self.stallTimeout) { [weak self] in
            self?.checkForStall(fedAt: now)
        }
        return true
    }

    func stop() {
        if let link = currentDisplayLink() {
            CVDisplayLinkStop(link)
        }
        let wasBypassing = withLock { () -> Bool in
            resetGlide()
            let wasBypassing = bypassing
            bypassing = false
            stallTimes.removeAll()
            return wasBypassing
        }
        if wasBypassing {
            GlideHealth.shared.report(.frames, problem: nil)
        }
    }

    /// Releases the frame source; the next glide creates a fresh one.
    func dropDisplayLink() {
        let old = withLinkLock { () -> CVDisplayLink? in
            let old = displayLink
            displayLink = nil
            return old
        }
        if let old {
            CVDisplayLinkStop(old)
        }
    }

    // MARK: - Watchdog

    /// Runs on the watchdog queue. If no frame has run since the wheel event
    /// was swallowed, deliver its whole remaining distance now.
    private func checkForStall(fedAt: UInt64) {
        let stalled = withLock { () -> (remaining: Double, template: CGEvent, horizontal: Bool)? in
            guard let template, lastTickAt < fedAt else {
                return nil
            }
            let result = (target - position, template, horizontal)
            resetGlide()
            return result
        }
        guard let stalled else {
            return
        }

        if abs(stalled.remaining) >= 1 {
            postFrame(from: stalled.template, step: stalled.remaining, horizontal: stalled.horizontal)
        }
        dropDisplayLink()

        let now = Self.now()
        let window = Self.nanoseconds(Self.stallWindow)
        let stalls = withLock { () -> Int in
            stallTimes = stallTimes.filter { now - $0 < window } + [now]
            return stallTimes.count
        }
        os_log("Glide frames stalled (%d in window); flushed %.1f pt", log: Self.log, type: .error, stalls, stalled.remaining)

        if stalls >= Self.stallsBeforeBypass {
            enterBypass(reason: NSLocalizedString("Glide stopped receiving display frames.", comment: ""))
        } else {
            GlideHealth.shared.count("frameStallsFlushed")
        }
    }

    private func enterBypass(reason: String) {
        let now = Self.now()
        withLock {
            bypassing = true
            bypassRetryAt = now + Self.nanoseconds(Self.bypassRetryInterval)
        }
        GlideHealth.shared.report(.frames, problem: reason)
    }

    // MARK: - Frames

    private func currentDisplayLink() -> CVDisplayLink? {
        withLinkLock { displayLink }
    }

    private func startDisplayLink() -> Bool {
        #if DEBUG
            if GlideFaults.shared.failLink {
                return false
            }
        #endif

        if startOrCreateDisplayLink() {
            return true
        }
        // A link can't be started again once the thread that created it has
        // exited (the tap thread, after macOS removes the tap and it is
        // rebuilt), so replace it before giving up.
        dropDisplayLink()
        return startOrCreateDisplayLink()
    }

    private func startOrCreateDisplayLink() -> Bool {
        var link = currentDisplayLink()
        if link == nil {
            var created: CVDisplayLink?
            guard CVDisplayLinkCreateWithActiveCGDisplays(&created) == kCVReturnSuccess, let created else {
                os_log("Failed to create display link", log: Self.log, type: .error)
                return false
            }
            CVDisplayLinkSetOutputCallback(created, { _, _, _, _, _, context in
                Unmanaged<GlideScrollingEngine>.fromOpaque(context!).takeUnretainedValue().tick()
                return kCVReturnSuccess
            }, Unmanaged.passUnretained(self).toOpaque())
            link = withLinkLock { () -> CVDisplayLink in
                if displayLink == nil {
                    displayLink = created
                }
                return displayLink!
            }
        }

        guard let link else {
            return false
        }
        if !CVDisplayLinkIsRunning(link), CVDisplayLinkStart(link) != kCVReturnSuccess {
            os_log("Failed to start display link", log: Self.log, type: .error)
            return false
        }
        return true
    }

    /// Runs on the display link thread.
    private func tick() {
        #if DEBUG
            if GlideFaults.shared.stallFrames {
                return
            }
        #endif

        let now = Self.now()
        let (step, template, horizontal, recovered) = withLock { () -> (Double, CGEvent?, Bool, Bool) in
            lastTickAt = now
            let recovered = bypassing
            if recovered {
                bypassing = false
                stallTimes.removeAll()
            }

            let step = (target - position) * Self.easing
            let template = self.template
            if abs(step) <= Self.stopThreshold {
                // Reset under the lock so input arriving now starts a fresh glide.
                resetGlide()
            } else {
                position += step
            }
            return (step, template, self.horizontal, recovered)
        }

        if recovered {
            GlideHealth.shared.report(.frames, problem: nil)
        }

        if let template {
            postFrame(from: template, step: step, horizontal: horizontal)
        }

        if abs(step) <= Self.stopThreshold, let link = currentDisplayLink() {
            CVDisplayLinkStop(link)
            if withLock({ self.template != nil }) {
                CVDisplayLinkStart(link)
            }
        }
    }

    private func postFrame(from template: CGEvent, step: Double, horizontal: Bool) {
        guard let event = template.copy() else {
            return
        }
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: horizontal ? 0 : step)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: horizontal ? step : 0)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 0)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: 0)
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.isLinearMouseSyntheticEvent = true
        post(event)
    }

    // MARK: - Helpers

    /// Call with `lock` held.
    private func resetGlide() {
        template = nil
        position = 0
        target = 0
        lastDelta = 0
    }

    private static func now() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }

    private static func nanoseconds(_ seconds: TimeInterval) -> UInt64 {
        UInt64(seconds * 1_000_000_000)
    }

    private func withLock<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return body()
    }

    private func withLinkLock<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(&linkLock)
        defer { os_unfair_lock_unlock(&linkLock) }
        return body()
    }
}
