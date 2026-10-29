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

    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var tap: CFMachPort?

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
    }

    func start() {
        guard thread == nil else {
            return
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
    }

    func stop() {
        guard thread != nil else {
            return
        }

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
        engine.stop()
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
              engine.feed(event, speed: glide.resolvedSpeed, reverse: glide.isReversed) else {
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
