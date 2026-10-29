// MIT License
// Copyright (c) 2021-2026 LinearMouse

import AppKit
import Combine
import Defaults
import Foundation
import os.log

/// Tracks whether Glide is really gliding, so a failure shows up as a
/// notification, a status line and a dimmed menu bar icon instead of quietly
/// changing how scrolling feels.
///
/// Problems are reported per component. Each one shows in the status right
/// away, but only notifies once it has lasted `notifyDelay`, so a hiccup that
/// recovers on its own is recorded without interrupting.
final class GlideHealth: ObservableObject {
    static let shared = GlideHealth()

    private static let log = OSLog(subsystem: Bundle.main.bundleIdentifier!, category: "GlideHealth")
    static let notifyDelay: TimeInterval = 3

    enum Component: String {
        case frames
        case tap
    }

    enum Status: Equatable {
        case active
        case off
        case degraded(String)
    }

    struct Incident: Equatable {
        var reason: String
        var recoveredAt: Date
    }

    struct CrashNotice: Equatable {
        var date: Date
        var restartedAutomatically: Bool
        var reportURL: URL?
    }

    @Published private(set) var status: Status = .active
    @Published private(set) var lastIncident: Incident?
    @Published private(set) var crashNotice: CrashNotice?

    // Main thread only.
    private var problems: [Component: String] = [:]
    private var pendingNotifications: [Component: DispatchWorkItem] = [:]
    private var notifiedPause = false
    private var counters: [String: Int] = [:]
    private var enabled = Defaults[.glideEnabled]

    init() {
        Defaults.observe(.glideEnabled, options: []) { [weak self] change in
            DispatchQueue.main.async {
                self?.enabled = change.newValue
                self?.update()
            }
        }
        .tieToLifetime(of: self)

        DispatchQueue.main.async {
            self.update()
        }
    }

    var needsAttention: Bool {
        if case .degraded = status {
            return true
        }
        return false
    }

    /// Reports a component's state from any thread; `nil` means healthy.
    func report(_ component: Component, problem: String?) {
        DispatchQueue.main.async {
            self.apply(component, problem: problem)
        }
    }

    /// Counts recoveries that never became visible problems (for the status file).
    func count(_ event: String) {
        DispatchQueue.main.async {
            self.counters[event, default: 0] += 1
            self.writeStatusFile()
        }
    }

    func setCrashNotice(_ notice: CrashNotice) {
        DispatchQueue.main.async {
            self.crashNotice = notice
            self.writeStatusFile()
        }
    }

    private func apply(_ component: Component, problem: String?) {
        let previous = problems[component]
        guard previous != problem else {
            return
        }

        problems[component] = problem
        if let problem {
            os_log("Glide %{public}@ problem: %{public}@", log: Self.log, type: .error, component.rawValue, problem)
            schedulePauseNotification(for: component, reason: problem)
        } else if let previous {
            os_log("Glide %{public}@ recovered from: %{public}@", log: Self.log, type: .info, component.rawValue, previous)
            pendingNotifications.removeValue(forKey: component)?.cancel()
            lastIncident = Incident(reason: previous, recoveredAt: Date())
            counters["recoveries", default: 0] += 1
        }
        update()

        if problems.isEmpty, notifiedPause {
            notifiedPause = false
            counters["restoredNotices", default: 0] += 1
            writeStatusFile()
            Notifier.shared.notify(
                title: NSLocalizedString("Glide restored", comment: ""),
                body: NSLocalizedString("Smooth scrolling is working again.", comment: "")
            )
        }
    }

    private func schedulePauseNotification(for component: Component, reason: String) {
        pendingNotifications[component]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, problems[component] == reason, enabled else {
                return
            }
            notifiedPause = true
            counters["pauseNotices", default: 0] += 1
            writeStatusFile()
            Notifier.shared.notify(
                title: NSLocalizedString("Glide paused", comment: ""),
                body: String(
                    format: NSLocalizedString(
                        "%@ Scrolling still works, without smoothing. LinearMouse Glide is trying to restore it.",
                        comment: ""
                    ),
                    reason
                )
            )
        }
        pendingNotifications[component] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.notifyDelay, execute: work)
    }

    private func update() {
        let newStatus: Status
        if !enabled {
            newStatus = .off
        } else if let reason = problems[.tap] ?? problems[.frames] {
            newStatus = .degraded(reason)
        } else {
            newStatus = .active
        }
        if status != newStatus {
            status = newStatus
        }
        writeStatusFile()
    }

    // MARK: - Status file

    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("LinearMouseGlide", isDirectory: true)
    }

    static var statusFileURL: URL {
        supportDirectory.appendingPathComponent("health.json")
    }

    /// Machine-readable state for the parity harness and for troubleshooting.
    private func writeStatusFile() {
        let statusName: String
        var reason: String?
        switch status {
        case .active:
            statusName = "active"
        case .off:
            statusName = "off"
        case let .degraded(problem):
            statusName = "degraded"
            reason = problem
        }

        var payload: [String: Any] = [
            "status": statusName,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "updated": ISO8601DateFormatter().string(from: Date()),
            "counters": counters,
            "restartedAfterCrash": crashNotice != nil
        ]
        payload["reason"] = reason
        payload["lastIncident"] = lastIncident?.reason

        do {
            try FileManager.default.createDirectory(at: Self.supportDirectory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: Self.statusFileURL, options: .atomic)
        } catch {
            os_log("Failed to write Glide status: %{public}@", log: Self.log, type: .error, String(describing: error))
        }
    }
}
