// MIT License
// Copyright (c) 2021-2026 LinearMouse

// Glide parity harness.
//
//   glide-parity record <out.json>        play scripted input, record what an app receives
//   glide-parity compare <a.json> <b.json> diff two recordings scenario by scenario
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
    private let outputURL: URL
    private var window: NSWindow!
    private var label: NSTextField!
    private let source = CGEventSource(stateID: .hidSystemState)

    private let lock = NSLock()
    private var current: [RecordedEvent] = []
    private var scenarioStart: UInt64 = 0
    private var lastEventAt = Date()
    private var physicalInputSeen = false
    private var recording = false

    init(outputURL: URL) {
        self.outputURL = outputURL
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
            self?.run()
        }
    }

    private func say(_ text: String) {
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

    private func post(_ step: Step) {
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

    private func waitForQuiet(quietMs: Double = 600, maxMs: Double = 4000) {
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

    private func centerCursor() {
        let frame = DispatchQueue.main.sync { window.frame }
        let screenHeight = NSScreen.screens[0].frame.height
        let center = CGPoint(x: frame.midX, y: screenHeight - frame.midY)
        CGWarpMouseCursorPosition(center)
        CGAssociateMouseAndMouseCursorPosition(1)
        usleep(100_000)
    }

    private func run() {
        say("Move your mouse once, then let go.")
        // GLIDE_PARITY_NOWAIT=1 trusts the stack's current last active device.
        while ProcessInfo.processInfo.environment["GLIDE_PARITY_NOWAIT"] == nil {
            usleep(50000)
            lock.lock()
            let seen = physicalInputSeen
            lock.unlock()
            if seen {
                break
            }
        }
        say("Hands off — recording…")
        sleep(2)

        var results: [ScenarioRecording] = []
        for scenario in scenarios {
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

// MARK: - Compare

/// Scenarios where LinearMouse Glide deliberately behaves differently from
/// LinearMouse + Mouse Glide. Differences there are reported, not failed.
let intendedDifferences = [
    "tilt-horizontal": "horizontal wheels glide sideways (Mouse Glide redirected them vertically)"
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

    for (sa, sb) in zip(a.scenarios, b.scenarios) {
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

// MARK: - Main

let arguments = CommandLine.arguments
switch arguments.dropFirst().first {
case "record" where arguments.count == 3:
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let recorder = Recorder(outputURL: URL(fileURLWithPath: arguments[2]))
    app.delegate = recorder
    app.run()
case "compare" where arguments.count == 4:
    let decoder = JSONDecoder()
    let a = try! decoder.decode(Recording.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[2])))
    let b = try! decoder.decode(Recording.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[3])))
    exit(compare(a, b) ? 0 : 1)
default:
    print("usage: glide-parity record <out.json> | compare <a.json> <b.json>")
    exit(2)
}
