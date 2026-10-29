// MIT License
// Copyright (c) 2021-2026 LinearMouse

import AppKit
import Combine
import Foundation
import os.log

/// Runs Glide where Mouse Glide ran: a tap at the annotated session stage,
/// appended after every other tap. It sees wheel events after LinearMouse's
/// HID tap has transformed them and after the window server has addressed
/// them to a target app, so the per-app rule comes from the event's target
/// process and replayed copies are delivered without moving the cursor.
final class GlideEventTap {
    static let shared = GlideEventTap()

    private static let log = OSLog(subsystem: Bundle.main.bundleIdentifier!, category: "GlideEventTap")

    private struct RouteKey: Hashable {
        var deviceID: Int32?
        var pid: pid_t?
        var display: String?
    }

    private let engine = GlideScrollingEngine.shared
    private let lock = NSLock()
    private var configuration = Configuration()
    private var routes: [RouteKey: Scheme.Scrolling.Glide] = [:]
    private var subscriptions = Set<AnyCancellable>()

    // Main thread only, except `tap`, which the tap thread also sets and
    // reads (to re-enable itself), so it goes through `lock`.
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var _tap: CFMachPort?
    private var tap: CFMachPort? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _tap
        }
        set {
            lock.lock()
            _tap = newValue
            lock.unlock()
        }
    }
    private var shouldRun = false
    private var healthTimer: Timer?
    private var retryWork: DispatchWorkItem?
    private var retryAttempt = 0

    private static let retryDelays: [TimeInterval] = [0.5, 1, 2, 5, 10]
    private static let healthCheckInterval: TimeInterval = 2

    init() {
        ConfigurationState.shared.$configuration
            .sink { [weak self] configuration in
                guard let self else {
                    return
                }
                lock.lock()
                self.configuration = configuration
                routes.removeAll()
                lock.unlock()
            }
            .store(in: &subscriptions)

        GlideFaults.shared.onInvalidateTap = { [weak self] in
            if let tap = self?.tap {
                CFMachPortInvalidate(tap)
            }
        }
    }

    func start() {
        guard !shouldRun else {
            return
        }
        shouldRun = true
        retryAttempt = 0
        startHealthChecks()
        attach()
    }

    func stop() {
        guard shouldRun else {
            return
        }
        shouldRun = false
        healthTimer?.invalidate()
        healthTimer = nil
        retryWork?.cancel()
        retryWork = nil
        detach()
        engine.stop()
        GlideHealth.shared.report(.tap, problem: nil)
    }

    // MARK: - Lifecycle

    @discardableResult
    private func attach() -> Bool {
        guard shouldRun, thread == nil else {
            return tap != nil
        }

        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            self?.runTap(signalling: ready)
        }
        thread.name = "GlideEventTap"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
        ready.wait()

        guard tap != nil else {
            self.thread = nil
            GlideHealth.shared.report(
                .tap,
                problem: NSLocalizedString("Glide couldn't attach to scroll events.", comment: "")
            )
            scheduleRetry()
            return false
        }

        retryAttempt = 0
        GlideHealth.shared.report(.tap, problem: nil)
        return true
    }

    private func detach() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoop {
            CFRunLoopStop(runLoop)
        }
        tap = nil
        runLoop = nil
        thread = nil
    }

    private func scheduleRetry() {
        guard shouldRun, retryWork == nil else {
            return
        }
        let delay = Self.retryDelays[min(retryAttempt, Self.retryDelays.count - 1)]
        retryAttempt += 1
        let work = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            retryWork = nil
            if tap == nil {
                attach()
            }
        }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func startHealthChecks() {
        healthTimer?.invalidate()
        let timer = Timer(timeInterval: Self.healthCheckInterval, repeats: true) { [weak self] _ in
            self?.checkHealth()
        }
        RunLoop.main.add(timer, forMode: .common)
        healthTimer = timer
    }

    /// Rebuilds the tap if macOS invalidated it, and re-enables it if disabled.
    private func checkHealth() {
        guard shouldRun else {
            return
        }
        guard let tap else {
            scheduleRetry()
            return
        }

        if !CFMachPortIsValid(tap) {
            os_log("Glide event tap was invalidated; rebuilding", log: Self.log, type: .error)
            GlideHealth.shared.report(.tap, problem: NSLocalizedString("macOS removed Glide's scroll hook.", comment: ""))
            GlideHealth.shared.count("tapRebuilds")
            detach()
            attach()
            return
        }

        if !CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
            GlideHealth.shared.count("tapReenables")
            if !CGEvent.tapIsEnabled(tap: tap) {
                os_log("Glide event tap stayed disabled; rebuilding", log: Self.log, type: .error)
                GlideHealth.shared.report(.tap, problem: NSLocalizedString("Glide's scroll hook was disabled.", comment: ""))
                detach()
                attach()
            }
        }
    }

    private func runTap(signalling ready: DispatchSemaphore) {
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgAnnotatedSessionEventTap,
            place: .tailAppendEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                Unmanaged<GlideEventTap>.fromOpaque(context!).takeUnretainedValue().handle(type, event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            os_log("Failed to create the Glide event tap", log: Self.log, type: .error)
            ready.signal()
            return
        }

        let runLoop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(runLoop, CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.runLoop = runLoop
        ready.signal()
        CFRunLoopRun()
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        case .scrollWheel:
            break
        default:
            return Unmanaged.passUnretained(event)
        }

        guard !event.isLinearMouseSyntheticEvent,
              engine.isEnabled,
              let glide = glide(for: event),
              glide.isEnabled,
              engine.feed(
                  event,
                  speed: glide.resolvedSpeed,
                  reverse: glide.isReversed,
                  leftMultiplier: glide.resolvedLeftMultiplier
              ) else {
            return Unmanaged.passUnretained(event)
        }
        return nil
    }

    private func glide(for event: CGEvent) -> Scheme.Scrolling.Glide? {
        let device = DeviceManager.shared.deviceFromCGEvent(event)
        // The window server leaves 1 (launchd) when it found no target app.
        let targetPid = pid_t(truncatingIfNeeded: event.getIntegerValueField(.eventTargetUnixProcessID))
        let pid = targetPid > 1 ? targetPid : nil
        let key = RouteKey(deviceID: device?.id, pid: pid, display: ScreenManager.shared.currentScreenNameSnapshot)

        lock.lock()
        defer { lock.unlock() }
        if let glide = routes[key] {
            return glide
        }
        let glide = configuration.matchScheme(withDevice: device, withPid: pid, withDisplay: key.display)
            .scrolling.glide
        routes[key] = glide
        return glide
    }
}
