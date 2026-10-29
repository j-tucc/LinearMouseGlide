// MIT License
// Copyright (c) 2021-2026 LinearMouse

// Glide parity harness.
//
//   glide-parity record <out.json>        play scripted input, record what an app receives
//   glide-parity compare <a.json> <b.json> diff two recordings scenario by scenario
//   glide-parity sample [seconds]          summarize physical horizontal wheel input, left vs right
//   glide-parity faults                    inject failures into a Debug LinearMouse Glide and check it fails open
//
// `record` opens a window under the cursor, waits for one physical mouse
// movement (so LinearMouse attributes the synthetic events to that mouse as
// its last active device), then posts each scenario's input at the HID tap and
// records every scroll event the window receives, with all CGEvent fields.
// Physical input during a scenario marks it as contaminated.

import AppKit
import CoreGraphics
import Foundation

// MARK: - Recording model

struct RecordedEvent: Codable {
    var t: Double // ms since scenario start
    var type: String
    var lineY: Int64
    var lineX: Int64
    var pointY: Double
    var pointX: Double
    var fixedY: Double
    var fixedX: Double
    var continuous: Int64
    var phase: Int64
    var momentum: Int64
    var flags: UInt64
    var x: Double
    var y: Double
    var nsDeltaY: Double
    var nsDeltaX: Double
    var precise: Bool
}

struct ScenarioRecording: Codable {
    var name: String
    var events: [RecordedEvent]
    var cursorMoved: Double? // for the cursor scenario: how far the cursor ended up from its start
    var contaminated: Bool
    var frontmostApp: String? // which app was active while the input played
}

struct Recording: Codable {
    var label: String
    var date: String
    var runningApps: [String]
    var scenarios: [ScenarioRecording]
}

// MARK: - Input scripting

enum Step {
    case wheel(y: Int32, x: Int32, flags: CGEventFlags)
    case pixel(y: Int32, x: Int32, phase: Int64)
    case move(dx: Double, dy: Double)
    case wait(ms: Double)
}

struct Scenario {
    var name: String
    var steps: [Step]
    var tracksCursor = false
    /// Play the input while another app (Finder) is frontmost, so the window
    /// under the cursor belongs to a background app.
    var inBackground = false
}

func repeated(_ count: Int, every ms: Double, _ step: Step) -> [Step] {
    (0 ..< count).flatMap { index in index == 0 ? [step] : [.wait(ms: ms), step] }
}

let notchDown = Step.wheel(y: -1, x: 0, flags: [])
let notchUp = Step.wheel(y: 1, x: 0, flags: [])

let scenarios: [Scenario] = [
    Scenario(name: "notch-down", steps: [notchDown]),
    Scenario(name: "notch-up", steps: [notchUp]),
    Scenario(name: "slow-notches-4x250ms", steps: repeated(4, every: 250, notchDown)),
    Scenario(name: "burst-5x40ms", steps: repeated(5, every: 40, notchDown)),
    Scenario(name: "spin-12x10ms", steps: repeated(12, every: 10, notchDown)),
    Scenario(
        name: "reverse-mid-glide",
        steps: repeated(3, every: 40, notchDown) + [.wait(ms: 40)] + repeated(3, every: 40, notchUp)
    ),
    Scenario(name: "shift-notch", steps: [.wheel(y: -1, x: 0, flags: .maskShift)]),
    Scenario(name: "option-notch", steps: [.wheel(y: -1, x: 0, flags: .maskAlternate)]),
    Scenario(name: "command-notch", steps: [.wheel(y: -1, x: 0, flags: .maskCommand)]),
    Scenario(name: "tilt-horizontal", steps: [.wheel(y: 0, x: -1, flags: [])]),
    Scenario(name: "tilt-right", steps: [.wheel(y: 0, x: 1, flags: [])]),
    Scenario(name: "pixel-continuous-no-phase", steps: repeated(3, every: 16, .pixel(y: -40, x: 0, phase: 0))),
    Scenario(
        name: "trackpad-phased",
        steps: [.pixel(y: -5, x: 0, phase: 1)] + repeated(4, every: 16, .pixel(y: -12, x: 0, phase: 2))
            + [.wait(ms: 16), .pixel(y: 0, x: 0, phase: 4)]
    ),
    Scenario(
        name: "cursor-move-during-glide",
        steps: repeated(3, every: 30, notchDown) + [.wait(ms: 10)] + repeated(10, every: 8, .move(dx: 10, dy: 0)),
        tracksCursor: true
    ),
    Scenario(name: "background-notch-down", steps: [notchDown], inBackground: true),
    Scenario(name: "background-burst-5x40ms", steps: repeated(5, every: 40, notchDown), inBackground: true),
    Scenario(
        name: "background-cursor-move",
        steps: repeated(3, every: 30, notchDown) + [.wait(ms: 10)] + repeated(10, every: 8, .move(dx: 10, dy: 0)),
        tracksCursor: true,
        inBackground: true
    )
]

// MARK: - Recorder

final class Recorder: NSObject, NSApplicationDelegate {
    enum Mode {
        case record(URL)
        case faults
    }

    private let mode: Mode
    private var window: NSWindow!
    private var label: NSTextField!
    private let source = CGEventSource(stateID: .hidSystemState)

    private let lock = NSLock()
    private var current: [RecordedEvent] = []
    private var scenarioStart: UInt64 = 0
    private var lastEventAt = Date()
    private var physicalInputSeen = false
    private var recording = false

    init(mode: Mode) {
        self.mode = mode
    }

    func applicationDidFinishLaunching(_: Notification) {
        let screen = NSScreen.main!.frame
        let size = NSSize(width: 640, height: 420)
        window = NSWindow(
            contentRect: NSRect(
                x: screen.midX - size.width / 2,
                y: screen.midY - size.height / 2,
                width: size.width,
                height: size.height
            ),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "Glide parity"
        window.level = .floating
        window.acceptsMouseMovedEvents = true
        label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 22, weight: .semibold)
        label.alignment = .center
        label.frame = NSRect(x: 20, y: size.height / 2 - 40, width: size.width - 40, height: 80)
        label.maximumNumberOfLines = 3
        window.contentView!.addSubview(label)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            self?.capture(event)
            return nil
        }
        NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .scrollWheel, .leftMouseDown]) { [weak self] event in
            self?.notePhysical(event)
        }
        NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown]) { [weak self] event in
            self?.notePhysical(event)
            return event
        }

        Thread.detachNewThread { [weak self] in
            guard let self else {
                return
            }
            switch mode {
            case let .record(outputURL):
                run(outputURL: outputURL)
            case .faults:
                exit(FaultSuite(recorder: self).run() ? 0 : 1)
            }
        }
    }

    func say(_ text: String) {
        DispatchQueue.main.async {
            self.label.stringValue = text
        }
        print(text)
    }

    private func notePhysical(_ event: NSEvent) {
        guard let cgEvent = event.cgEvent,
              cgEvent.getIntegerValueField(.eventSourceUnixProcessID) == 0 else {
            return
        }
        lock.lock()
        physicalInputSeen = true
        lock.unlock()
    }

    private func capture(_ event: NSEvent) {
        guard let cg = event.cgEvent else {
            return
        }
        lock.lock()
        defer { lock.unlock() }
        guard recording else {
            return
        }
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        current.append(RecordedEvent(
            t: Double(now - scenarioStart) / 1_000_000,
            type: "scroll",
            lineY: cg.getIntegerValueField(.scrollWheelEventDeltaAxis1),
            lineX: cg.getIntegerValueField(.scrollWheelEventDeltaAxis2),
            pointY: cg.getDoubleValueField(.scrollWheelEventPointDeltaAxis1),
            pointX: cg.getDoubleValueField(.scrollWheelEventPointDeltaAxis2),
            fixedY: cg.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1),
            fixedX: cg.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2),
            continuous: cg.getIntegerValueField(.scrollWheelEventIsContinuous),
            phase: cg.getIntegerValueField(.scrollWheelEventScrollPhase),
            momentum: cg.getIntegerValueField(.scrollWheelEventMomentumPhase),
            flags: cg.flags.rawValue & 0x00FF_0000, // modifier keys only
            x: cg.location.x,
            y: cg.location.y,
            nsDeltaY: Double(event.scrollingDeltaY),
            nsDeltaX: Double(event.scrollingDeltaX),
            precise: event.hasPreciseScrollingDeltas
        ))
        lastEventAt = Date()
    }

    private var cursorLocation: CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    func post(_ step: Step) {
        switch step {
        case let .wheel(y, x, flags):
            guard let event = CGEvent(
                scrollWheelEvent2Source: source, units: .line, wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0
            ) else {
                return
            }
            event.flags = flags
            event.location = cursorLocation
            event.post(tap: .cghidEventTap)
        case let .pixel(y, x, phase):
            guard let event = CGEvent(
                scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0
            ) else {
                return
            }
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            event.location = cursorLocation
            event.post(tap: .cghidEventTap)
        case let .move(dx, dy):
            let from = cursorLocation
            let to = CGPoint(x: from.x + dx, y: from.y + dy)
            guard let event = CGEvent(
                mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: to, mouseButton: .left
            ) else {
                return
            }
            event.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx))
            event.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy))
            event.post(tap: .cghidEventTap)
        case let .wait(ms):
            usleep(useconds_t(ms * 1000))
        }
    }

    func waitForQuiet(quietMs: Double = 600, maxMs: Double = 4000) {
        let deadline = Date().addingTimeInterval(maxMs / 1000)
        while Date() < deadline {
            usleep(20000)
            lock.lock()
            let idle = Date().timeIntervalSince(lastEventAt) * 1000
            lock.unlock()
            if idle >= quietMs {
                return
            }
        }
    }

    func centerCursor() {
        let frame = DispatchQueue.main.sync { window.frame }
        let screenHeight = NSScreen.screens[0].frame.height
        let center = CGPoint(x: frame.midX, y: screenHeight - frame.midY)
        CGWarpMouseCursorPosition(center)
        CGAssociateMouseAndMouseCursorPosition(1)
        usleep(100_000)
    }

    /// Waits for one physical mouse movement; false if `timeout` passes first.
    @discardableResult
    func waitForPhysicalMove(_ prompt: String = "Move your mouse once, then let go.", timeout: Double = .infinity) -> Bool {
        lock.lock()
        physicalInputSeen = false
        lock.unlock()
        say(prompt)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            usleep(50000)
            lock.lock()
            let seen = physicalInputSeen
            lock.unlock()
            if seen {
                return true
            }
        }
        return false
    }

    /// Plays `steps` with this window frontmost and returns what it received.
    func probe(_ steps: [Step], maxMs: Double = 4000) -> (events: [RecordedEvent], contaminated: Bool) {
        centerCursor()
        DispatchQueue.main.sync {
            NSApp.activate(ignoringOtherApps: true)
        }
        usleep(200_000)
        lock.lock()
        current = []
        physicalInputSeen = false
        lastEventAt = Date()
        scenarioStart = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        recording = true
        lock.unlock()

        for step in steps {
            post(step)
        }
        waitForQuiet(maxMs: maxMs)

        lock.lock()
        recording = false
        let result = (current, physicalInputSeen)
        lock.unlock()
        return result
    }

    private func run(outputURL: URL) {
        // GLIDE_PARITY_NOWAIT=1 trusts the stack's current last active device.
        if ProcessInfo.processInfo.environment["GLIDE_PARITY_NOWAIT"] == nil {
            waitForPhysicalMove()
        }
        say("Hands off — recording…")
        sleep(2)

        var results: [ScenarioRecording] = []
        // GLIDE_PARITY_ONLY=a,b records just those scenarios.
        let only = ProcessInfo.processInfo.environment["GLIDE_PARITY_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        for scenario in scenarios where only?.contains(scenario.name) ?? true {
            centerCursor()
            lock.lock()
            current = []
            physicalInputSeen = false
            lastEventAt = Date()
            scenarioStart = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            recording = true
            lock.unlock()

            if scenario.inBackground {
                DispatchQueue.main.sync {
                    NSWorkspace.shared.runningApplications
                        .first { $0.bundleIdentifier == "com.apple.finder" }?
                        .activate()
                }
                usleep(500_000)
            } else {
                DispatchQueue.main.sync {
                    NSApp.activate(ignoringOtherApps: true)
                }
                usleep(200_000)
            }
            let frontmostApp = DispatchQueue.main.sync {
                NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            }

            let start = cursorLocation
            say("Hands off — \(scenario.name)")
            for step in scenario.steps {
                post(step)
            }
            waitForQuiet()

            lock.lock()
            recording = false
            let events = current
            let contaminated = physicalInputSeen
            lock.unlock()

            let end = cursorLocation
            results.append(ScenarioRecording(
                name: scenario.name,
                events: events,
                cursorMoved: scenario.tracksCursor ? hypot(end.x - start.x, end.y - start.y) : nil,
                contaminated: contaminated,
                frontmostApp: frontmostApp
            ))
            usleep(300_000)
        }

        let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier).filter {
            $0.contains("LinearMouse") || $0.contains("linearmouse") || $0.contains("MouseGlide")
        }
        let recording = Recording(
            label: outputURL.deletingPathExtension().lastPathComponent,
            date: ISO8601DateFormatter().string(from: Date()),
            runningApps: running,
            scenarios: results
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try! encoder.encode(recording).write(to: outputURL)
        say("Done — wrote \(outputURL.lastPathComponent)")
        sleep(1)
        exit(0)
    }
}

// MARK: - Faults

/// Breaks a running Debug build of LinearMouse Glide in each way its failure
/// handling covers, through its debug fault notification, and checks that
/// every wheel notch still scrolls, that the status file reports the problem
/// and the recovery, and that a crash brings the app back.
final class FaultSuite {
    static let faultNotification = Notification.Name("app.linearmouseglide.debug.fault")
    static let healthURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/LinearMouseGlide/health.json")

    private let recorder: Recorder
    private var failures = 0

    init(recorder: Recorder) {
        self.recorder = recorder
    }

    enum Delivery: Equatable {
        case none
        case raw // passed through unsmoothed
        case flushed // one frame carrying the whole glide
        case glided
    }

    struct Delivered {
        var delivery: Delivery
        var frames: Int
        var total: Double
        var contaminated: Bool

        var summary: String {
            "\(delivery) — \(frames) event(s), \(String(format: "%.0f", total)) pt" + (contaminated ? " (physical input seen)" : "")
        }
    }

    // MARK: Helpers

    private func inject(_ fault: String) {
        DistributedNotificationCenter.default().postNotificationName(
            Self.faultNotification, object: fault, userInfo: nil, deliverImmediately: true
        )
        usleep(300_000)
    }

    private func health() -> [String: Any] {
        guard let data = try? Data(contentsOf: Self.healthURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }

    private func status() -> String {
        health()["status"] as? String ?? "missing"
    }

    private func counter(_ name: String) -> Int {
        (health()["counters"] as? [String: Int])?[name] ?? 0
    }

    private func waitUntil(_ timeout: Double, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() {
                return true
            }
            usleep(100_000)
        } while Date() < deadline
        return condition()
    }

    /// One wheel notch: was it delivered, and how? (Its direction depends on
    /// the device's reverse settings, so any non-zero distance counts.)
    private func notch(maxMs: Double = 4000) -> Delivered {
        let (events, contaminated) = recorder.probe([notchDown], maxMs: maxMs)
        let total = events.reduce(0) { $0 + $1.pointY }
        let delivery: Delivery
        if events.isEmpty || total == 0 {
            delivery = .none
        } else if events.contains(where: { $0.continuous == 0 }) {
            delivery = .raw
        } else if events.count == 1 {
            delivery = .flushed
        } else {
            delivery = .glided
        }
        return Delivered(delivery: delivery, frames: events.count, total: total, contaminated: contaminated)
    }

    private func check(_ name: String, _ passed: Bool, _ detail: String) {
        if !passed {
            failures += 1
        }
        recorder.say("\(passed ? "PASS" : "FAIL")  \(name): \(detail)")
    }

    private func expect(_ name: String, _ delivered: Delivered, _ allowed: Set<Delivery>) {
        check(name, allowed.contains(delivered.delivery), delivered.summary)
    }

    // MARK: Tests

    func run() -> Bool {
        // GLIDE_PARITY_NOWAIT=1 trusts the app's current last active device.
        if ProcessInfo.processInfo.environment["GLIDE_PARITY_NOWAIT"] == nil {
            recorder.waitForPhysicalMove()
        }
        recorder.say("Hands off — fault tests…")
        sleep(2)
        inject("clear")

        guard let pid = health()["pid"] as? Int else {
            recorder.say("FAIL  LinearMouse Glide isn't running a Debug build with a status file")
            return false
        }
        check("starts healthy", status() == "active", "status \(status()), pid \(pid)")
        expect("baseline notch glides", notch(), [.glided])

        // GLIDE_FAULTS_ONLY=tap,crash runs just those tests.
        let only = ProcessInfo.processInfo.environment["GLIDE_FAULTS_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        let tests: [(String, () -> Void)] = [
            ("stall", stallFrames),
            ("link", failLink),
            ("tap", invalidateTap),
            ("crash", { self.crash(pid: pid) })
        ]
        for (name, test) in tests where only?.contains(name) ?? true {
            test()
        }

        inject("clear")
        recorder.say(failures == 0 ? "All fault tests passed." : "\(failures) check(s) failed.")
        sleep(1)
        return failures == 0
    }

    /// Display frames stop arriving: the watchdog flushes each glide, then
    /// after two stalls Glide passes notches through until frames return.
    private func stallFrames() {
        let flushedBefore = counter("frameStallsFlushed")
        let pausesBefore = counter("pauseNotices")
        let restoredBefore = counter("restoredNotices")
        inject("stall-frames")

        expect("stalled frames: 1st notch flushed by watchdog", notch(), [.flushed])
        check("stalled frames: flush counted", counter("frameStallsFlushed") == flushedBefore + 1, "frameStallsFlushed \(counter("frameStallsFlushed"))")
        expect("stalled frames: 2nd notch flushed by watchdog", notch(), [.flushed])
        check("stalled frames: status degraded after 2 stalls", waitUntil(1) { status() == "degraded" }, "status \(status()), reason \(health()["reason"] ?? "-")")
        let bypassedAt = Date()
        expect("stalled frames: notch passes through", notch(), [.raw])
        check("stalled frames: pause notification sent", waitUntil(4) { counter("pauseNotices") == pausesBefore + 1 }, "pauseNotices \(counter("pauseNotices"))")

        inject("clear")
        Thread.sleep(until: bypassedAt.addingTimeInterval(5.5))
        expect("stalled frames: glides again once frames return", notch(), [.glided])
        check("stalled frames: status active again", waitUntil(1) { status() == "active" }, "status \(status()), lastIncident \(health()["lastIncident"] ?? "-")")
        check("stalled frames: restored notification sent", waitUntil(1) { counter("restoredNotices") == restoredBefore + 1 }, "restoredNotices \(counter("restoredNotices"))")
    }

    /// The frame source can't start: notches pass through at once.
    private func failLink() {
        inject("fail-link")
        let bypassedAt = Date()
        expect("no frame source: notch passes through", notch(), [.raw])
        check("no frame source: status degraded", waitUntil(1) { status() == "degraded" }, "status \(status()), reason \(health()["reason"] ?? "-")")
        expect("no frame source: next notch passes through", notch(), [.raw])

        inject("clear")
        Thread.sleep(until: bypassedAt.addingTimeInterval(5.5))
        expect("no frame source: glides again once it starts", notch(), [.glided])
        check("no frame source: status active again", waitUntil(1) { status() == "active" }, "status \(status())")
    }

    /// macOS invalidates Glide's tap: notches pass unsmoothed until the
    /// health check rebuilds it.
    private func invalidateTap() {
        let rebuildsBefore = counter("tapRebuilds")
        inject("invalidate-tap")
        expect("tap removed: notch still delivered", notch(maxMs: 1500), [.raw, .glided])
        check("tap removed: rebuilt by health check", waitUntil(3) { counter("tapRebuilds") == rebuildsBefore + 1 }, "tapRebuilds \(counter("tapRebuilds"))")
        check("tap removed: status active", waitUntil(1) { status() == "active" }, "status \(status()), lastIncident \(health()["lastIncident"] ?? "-")")
        expect("tap removed: glides after rebuild", notch(), [.glided])
    }

    /// The app crashes: scrolling keeps working and it comes back.
    private func crash(pid: Int) {
        // Forget earlier test crashes, so repeated runs don't trip the
        // crash-loop guard (3 crashes in 10 minutes stops auto-restart).
        try? FileManager.default.removeItem(at: Self.healthURL.deletingLastPathComponent().appendingPathComponent("crashes.json"))
        inject("crash")
        // A crashing process lingers while macOS writes its crash report.
        check("crash: app process gone", waitUntil(15) { kill(pid_t(pid), 0) != 0 }, "pid \(pid)")
        sleep(1)
        expect("crash: notch still delivered while it's down", notch(maxMs: 3000), [.raw])

        recorder.say("Waiting for LinearMouse Glide to restart…")
        let restarted = waitUntil(45) {
            let newPid = health()["pid"] as? Int
            return newPid != nil && newPid != pid && health()["restartedAfterCrash"] as? Bool == true
        }
        check("crash: restarted with crash notice", restarted, "pid \(health()["pid"] ?? "-"), restartedAfterCrash \(health()["restartedAfterCrash"] ?? "-")")
        guard restarted else {
            return
        }
        sleep(2)

        // The new instance needs one physical event to know which mouse is active.
        if recorder.waitForPhysicalMove("Restarted. Move your mouse once more, then let go.", timeout: 60) {
            recorder.say("Hands off…")
            sleep(2)
            expect("crash: glides after restart", notch(), [.glided])
        } else {
            check("crash: glides after restart", false, "no mouse movement within 60 s, not checked")
        }
    }
}

// MARK: - Compare

/// Scenarios where LinearMouse Glide deliberately behaves differently from
/// LinearMouse + Mouse Glide. Differences there are reported, not failed.
let intendedDifferences = [
    "tilt-horizontal": "horizontal wheels glide sideways (Mouse Glide redirected them vertically)",
    "tilt-right": "horizontal wheels glide sideways (Mouse Glide redirected them vertically)"
]

func compare(_ a: Recording, _ b: Recording) -> Bool {
    print("Comparing \(a.label) [\(a.runningApps.joined(separator: ", "))]")
    print("     with \(b.label) [\(b.runningApps.joined(separator: ", "))]\n")
    var allPass = true

    func summary(_ events: [RecordedEvent]) -> String {
        let sumY = events.map(\.pointY).reduce(0, +)
        let sumX = events.map(\.pointX).reduce(0, +)
        let duration = (events.last?.t ?? 0) - (events.first?.t ?? 0)
        return String(format: "%3d events  ΣY %8.2f  ΣX %8.2f  %5.0f ms", events.count, sumY, sumX, duration)
    }

    let scenariosB = Dictionary(b.scenarios.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    for sa in a.scenarios {
        guard let sb = scenariosB[sa.name] else {
            continue
        }
        var problems: [String] = []
        if sa.contaminated || sb.contaminated {
            problems.append("physical input during recording — rerun")
        }
        if sa.frontmostApp != sb.frontmostApp {
            problems.append("frontmost app differed: \(sa.frontmostApp ?? "?") vs \(sb.frontmostApp ?? "?")")
        }
        if sa.events.isEmpty != sb.events.isEmpty {
            problems.append("only one stack delivered any scroll events to the window")
        }

        let ea = sa.events, eb = sb.events
        let sumYa = ea.map(\.pointY).reduce(0, +), sumYb = eb.map(\.pointY).reduce(0, +)
        let sumXa = ea.map(\.pointX).reduce(0, +), sumXb = eb.map(\.pointX).reduce(0, +)
        let tolerance = { (total: Double) in max(2, abs(total) * 0.05) }
        if abs(sumYa - sumYb) > tolerance(sumYa) || abs(sumXa - sumXb) > tolerance(sumXa) {
            problems.append(String(format: "total distance differs: Y %.2f vs %.2f, X %.2f vs %.2f", sumYa, sumYb, sumXa, sumXb))
        }
        // macOS coalesces frames the window reads late, so counts may differ by a couple.
        if abs(ea.count - eb.count) > 2 {
            problems.append("event count \(ea.count) vs \(eb.count)")
        }
        let durA = (ea.last?.t ?? 0) - (ea.first?.t ?? 0), durB = (eb.last?.t ?? 0) - (eb.first?.t ?? 0)
        if abs(durA - durB) > 20 {
            problems.append(String(format: "duration %.0f ms vs %.0f ms", durA, durB))
        }

        // Compare scroll position over time rather than event by event, so a
        // frame landing one vsync earlier or later is not a difference.
        func position(_ events: [RecordedEvent], at time: Double) -> Double {
            let origin = events.first?.t ?? 0
            return events.filter { $0.t - origin <= time }.reduce(0) { $0 + $1.pointY + $1.pointX }
        }
        let largestFrame = (ea + eb).map { abs($0.pointY) + abs($0.pointX) }.max() ?? 0
        var worst = (deviation: 0.0, time: 0.0)
        for time in stride(from: 0.0, through: max(durA, durB), by: 1) {
            let deviation = abs(position(ea, at: time) - position(eb, at: time))
            if deviation > worst.deviation {
                worst = (deviation, time)
            }
        }
        if worst.deviation > largestFrame + 1 {
            problems.append(String(
                format: "scroll position diverges by %.1f pt at %.0f ms (more than one frame)",
                worst.deviation, worst.time
            ))
        }

        func signature(_ events: [RecordedEvent]) -> Set<String> {
            Set(events.map {
                let axis = $0.pointY != 0 ? "Y" : $0.pointX != 0 ? "X" : "-"
                return "axis=\(axis) cont=\($0.continuous) phase=\($0.phase) mom=\($0.momentum) flags=\(String($0.flags, radix: 16)) precise=\($0.precise)"
            })
        }
        let sigA = signature(ea), sigB = signature(eb)
        if sigA != sigB {
            problems.append("event fields differ:\n          only \(a.label): \(sigA.subtracting(sigB).sorted())\n          only \(b.label): \(sigB.subtracting(sigA).sorted())")
        }

        if let movedA = sa.cursorMoved, let movedB = sb.cursorMoved, abs(movedA - movedB) > 5 {
            problems.append(String(format: "cursor moved %.0f pt vs %.0f pt", movedA, movedB))
        }

        let intended = intendedDifferences[sa.name]
        let status = problems.isEmpty ? "PASS" : intended != nil ? "KNOWN" : "DIFF"
        allPass = allPass && (problems.isEmpty || intended != nil)
        if let intended, !problems.isEmpty {
            problems.insert("intended: \(intended)", at: 0)
        }
        print("\(status)  \(sa.name)")
        print("      \(a.label): \(summary(ea))")
        print("      \(b.label): \(summary(eb))")
        for problem in problems {
            print("      - \(problem)")
        }
    }
    return allPass
}

// MARK: - Sample

/// Records physical wheel events at two points for `seconds`: raw from the
/// device (HID tap, ahead of LinearMouse) and after LinearMouse's rules
/// (annotated session tap, ahead of Glide), then prints a per-direction summary.
final class Sampler {
    struct Sample {
        var stage: String
        var time: Double
        var line: Int64
        var point: Double
        var fixed: Double
        var continuous: Int64
        var verticalLine: Int64
        var verticalPoint: Double
        var shift: Bool
    }

    private let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)

    private var samples: [Sample] = []
    private var taps: [CFMachPort] = []

    func run(seconds: Double) {
        install(at: .cghidEventTap, place: .headInsertEventTap, stage: "raw")
        install(at: .cgAnnotatedSessionEventTap, place: .headInsertEventTap, stage: "after LinearMouse")
        print("Scroll the horizontal wheel LEFT, pause, then RIGHT, the same number of notches (\(Int(seconds)) s)…")
        print("\u{7}", terminator: "")
        NSSound.beep()
        CFRunLoopRunInMode(.defaultMode, seconds, false)
        NSSound.beep()
        print("\(samples.filter { $0.stage == "raw" }.count) physical scroll events in total")
        report()
    }

    private func install(at location: CGEventTapLocation, place: CGEventTapPlacement, stage: String) {
        let box = Unmanaged.passRetained(StageBox(sampler: self, stage: stage)).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: location,
            place: place,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(1 << CGEventType.scrollWheel.rawValue),
            callback: { _, _, event, context in
                let box = Unmanaged<StageBox>.fromOpaque(context!).takeUnretainedValue()
                box.sampler.record(event, stage: box.stage)
                return Unmanaged.passUnretained(event)
            },
            userInfo: box
        ) else {
            print("could not create \(stage) tap")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        taps.append(tap)
    }

    private final class StageBox {
        let sampler: Sampler
        let stage: String

        init(sampler: Sampler, stage: String) {
            self.sampler = sampler
            self.stage = stage
        }
    }

    fileprivate func record(_ event: CGEvent, stage: String) {
        // Physical input only: synthetic events carry their poster's pid, and
        // Glide frames (copies of physical events) carry LinearMouse's marker.
        guard event.getIntegerValueField(.eventSourceUnixProcessID) == 0,
              event.getIntegerValueField(.eventSourceUserData) != 0x534D_4F4F_5448 else {
            return
        }
        let sample = Sample(
            stage: stage,
            time: Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / 1_000_000_000,
            line: event.getIntegerValueField(.scrollWheelEventDeltaAxis2),
            point: event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2),
            fixed: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2),
            continuous: event.getIntegerValueField(.scrollWheelEventIsContinuous),
            verticalLine: event.getIntegerValueField(.scrollWheelEventDeltaAxis1),
            verticalPoint: event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1),
            shift: event.flags.contains(.maskShift)
        )
        samples.append(sample)
        if stage == "raw" {
            print(String(
                format: "%6.2fs raw  vertical line %3lld pt %7.1f | horizontal line %3lld pt %7.1f | shift=%@ continuous=%lld",
                sample.time, sample.verticalLine, sample.verticalPoint, sample.line, sample.point,
                sample.shift ? "yes" : "no", sample.continuous
            ))
        }
    }

    private func report() {
        if let first = samples.first(where: { $0.stage == "raw" && ($0.point != 0 || $0.line != 0) }) {
            print(String(format: "first raw event (scrolled left first): point %.1f line %lld", first.point, first.line))
        }
        for stage in ["raw", "after LinearMouse"] {
            for (name, isLeft) in [("left", true), ("right", false)] {
                // Measured on a Keychron side wheel: scrolling left is negative.
                let events = samples.filter {
                    $0.stage == stage && ($0.point != 0 || $0.line != 0)
                        && (($0.point != 0 ? $0.point : Double($0.line)) < 0) == isLeft
                }
                guard !events.isEmpty else {
                    print(String(format: "%-18@ %-5@ no events", stage as NSString, name as NSString))
                    continue
                }
                let points = events.map { abs($0.point) }
                let lines = events.map { abs($0.line) }
                print(String(
                    format: "%-18@ %-5@ %3d events  Σline %4lld  Σpoint %7.1f  point/event min %.1f avg %.1f max %.1f  continuous=%@",
                    stage as NSString, name as NSString, events.count, lines.reduce(0, +), points.reduce(0, +),
                    points.min()!, points.reduce(0, +) / Double(points.count), points.max()!,
                    Set(events.map(\.continuous)).map(String.init).joined(separator: ",") as NSString
                ))
            }
        }
    }
}

// MARK: - Main

let arguments = CommandLine.arguments
switch arguments.dropFirst().first {
case "record" where arguments.count == 3:
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let recorder = Recorder(mode: .record(URL(fileURLWithPath: arguments[2])))
    app.delegate = recorder
    app.run()
case "faults":
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let recorder = Recorder(mode: .faults)
    app.delegate = recorder
    app.run()
case "sample":
    Sampler().run(seconds: arguments.count > 2 ? Double(arguments[2]) ?? 20 : 20)
case "compare" where arguments.count == 4:
    let decoder = JSONDecoder()
    let a = try! decoder.decode(Recording.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[2])))
    let b = try! decoder.decode(Recording.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[3])))
    exit(compare(a, b) ? 0 : 1)
default:
    print("usage: glide-parity record <out.json> | compare <a.json> <b.json> | sample [seconds] | faults")
    exit(2)
}
