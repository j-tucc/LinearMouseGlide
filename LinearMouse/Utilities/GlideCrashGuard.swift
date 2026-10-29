// MIT License
// Copyright (c) 2021-2026 LinearMouse

import AppKit
import Foundation
import os.log

/// Brings LinearMouse Glide back after a crash, and says so.
///
/// Each run writes a session lock and starts a small guardian shell process
/// that waits for the app to exit. A normal quit removes the lock first. If
/// the app dies with the lock still there and macOS writes a crash report
/// for it, the guardian relaunches it with `--after-crash`, and the new run
/// posts a notification and shows the crash in the Glide pane.
///
/// An exit without a crash report (force quit, `kill`, power loss) is not
/// treated as a crash, so a deliberate force quit stays quit. After
/// `maxRestarts` crashes within `restartWindow`, the guardian is not armed,
/// so a crash loop ends with the app staying down.
final class GlideCrashGuard {
    static let shared = GlideCrashGuard()

    private static let log = OSLog(subsystem: Bundle.main.bundleIdentifier!, category: "GlideCrashGuard")

    static let afterCrashArgument = "--after-crash"
    static let maxRestarts = 3
    static let restartWindow: TimeInterval = 10 * 60
    /// How long the guardian waits for macOS to write the crash report.
    static let crashReportWait = 20

    private struct Session: Codable {
        var pid: pid_t
        var started: Date
    }

    private var lockURL: URL {
        GlideHealth.supportDirectory.appendingPathComponent("session.lock")
    }

    private var guardianLogURL: URL {
        GlideHealth.supportDirectory.appendingPathComponent("guardian.log")
    }

    private var crashHistoryURL: URL {
        GlideHealth.supportDirectory.appendingPathComponent("crashes.json")
    }

    private static var crashReportsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
    }

    /// Call once at launch, before anything that could crash.
    func begin() {
        do {
            try FileManager.default.createDirectory(at: GlideHealth.supportDirectory, withIntermediateDirectories: true)
        } catch {
            os_log("Failed to create support directory: %{public}@", log: Self.log, type: .error, String(describing: error))
            return
        }

        var armGuardian = true
        if let previous = readSession(), previous.pid != ProcessInfo.processInfo.processIdentifier {
            armGuardian = handleAbnormalExit(of: previous)
        }

        writeSession()
        if armGuardian {
            startGuardian()
        }
    }

    /// Call when the app quits normally. Leaves a lock that belongs to
    /// another copy of the app (a Debug build next to the installed one).
    func end() {
        guard readSession()?.pid == ProcessInfo.processInfo.processIdentifier else {
            return
        }
        try? FileManager.default.removeItem(at: lockURL)
    }

    // MARK: - Previous run

    /// Returns whether the guardian should be armed for this run.
    private func handleAbnormalExit(of previous: Session) -> Bool {
        guard let report = crashReport(since: previous.started) else {
            os_log("Previous run (pid %d) exited without quitting or a crash report", log: Self.log, type: .info, previous.pid)
            return true
        }

        let restartedAutomatically = CommandLine.arguments.contains(Self.afterCrashArgument)
        let recentCrashes = recordCrash()
        os_log(
            "Previous run (pid %d) crashed (%{public}@); %d crash(es) in the last %.0f s",
            log: Self.log,
            type: .error,
            previous.pid,
            report.lastPathComponent,
            recentCrashes,
            Self.restartWindow
        )

        GlideHealth.shared.setCrashNotice(.init(
            date: (try? report.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date(),
            restartedAutomatically: restartedAutomatically,
            reportURL: report
        ))

        let keepsCrashing = recentCrashes >= Self.maxRestarts
        if keepsCrashing {
            Notifier.shared.notify(
                title: NSLocalizedString("LinearMouse Glide keeps crashing", comment: ""),
                body: NSLocalizedString(
                    "It won't restart itself again if it crashes. Scrolling goes back to normal macOS scrolling if it does.",
                    comment: ""
                )
            )
        } else if restartedAutomatically {
            Notifier.shared.notify(
                title: NSLocalizedString("LinearMouse Glide restarted after a crash", comment: ""),
                body: NSLocalizedString("Smooth scrolling is back. The crash report is in Settings → Glide.", comment: "")
            )
        } else {
            Notifier.shared.notify(
                title: NSLocalizedString("LinearMouse Glide crashed last time", comment: ""),
                body: NSLocalizedString("The crash report is in Settings → Glide.", comment: "")
            )
        }
        return !keepsCrashing
    }

    /// The newest crash report for this app written after `date`.
    private func crashReport(since date: Date) -> URL? {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: Self.crashReportsDirectory,
            includingPropertiesForKeys: keys
        ) else {
            return nil
        }

        let executable = Bundle.main.executableURL?.lastPathComponent ?? "LinearMouse"
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? ""
        return files
            .filter { $0.lastPathComponent.hasPrefix(executable) && $0.pathExtension == "ips" }
            .compactMap { url -> (URL, Date)? in
                guard let modified = try? url.resourceValues(forKeys: Set(keys)).contentModificationDate,
                      modified >= date else {
                    return nil
                }
                return (url, modified)
            }
            .sorted { $0.1 > $1.1 }
            .first { url, _ in
                // Upstream LinearMouse has the same executable name; the
                // report's header line names the bundle.
                guard let handle = try? FileHandle(forReadingFrom: url) else {
                    return false
                }
                defer { try? handle.close() }
                let header = String(decoding: handle.readData(ofLength: 4096), as: UTF8.self)
                return header.contains("\"bundleID\":\"\(bundleIdentifier)\"")
            }?
            .0
    }

    /// Records a crash and returns how many happened within `restartWindow`.
    private func recordCrash() -> Int {
        let now = Date()
        var history = (try? JSONDecoder().decode([Date].self, from: Data(contentsOf: crashHistoryURL))) ?? []
        history = history.filter { now.timeIntervalSince($0) < Self.restartWindow } + [now]
        if let data = try? JSONEncoder().encode(history) {
            try? data.write(to: crashHistoryURL, options: .atomic)
        }
        return history.count
    }

    // MARK: - Session lock

    private func readSession() -> Session? {
        guard let data = try? Data(contentsOf: lockURL) else {
            return nil
        }
        return try? JSONDecoder().decode(Session.self, from: data)
    }

    private func writeSession() {
        let session = Session(pid: ProcessInfo.processInfo.processIdentifier, started: Date())
        do {
            try JSONEncoder().encode(session).write(to: lockURL, options: .atomic)
        } catch {
            os_log("Failed to write session lock: %{public}@", log: Self.log, type: .error, String(describing: error))
        }
    }

    // MARK: - Guardian

    /// Starts a shell that outlives a crash: once this process is gone, if
    /// the lock is still there and a crash report for this bundle appears,
    /// it relaunches the app. What it did goes to `guardian.log`.
    private func startGuardian() {
        let script = """
        log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [$PID] $*"; }
        trap '' HUP
        log "watching"
        while kill -0 "$PID" 2>/dev/null; do sleep 1; done
        if [ ! -f "$LOCK" ]; then log "quit normally"; exit 0; fi
        log "exited without quitting; waiting for a crash report"
        i=0
        while [ $i -lt "$WAIT" ]; do
          for f in "$REPORTS"/"$EXE"*.ips; do
            if [ -f "$f" ] && [ "$f" -nt "$LOCK" ] && grep -q "\\"bundleID\\":\\"$BUNDLE\\"" "$f"; then
              log "crashed ($f); relaunching"
              exec /usr/bin/open -g "$APP" --args \(Self.afterCrashArgument)
            fi
          done
          sleep 1
          i=$((i + 1))
        done
        log "no crash report; not relaunching"
        """

        let environment = [
            "PATH": "/usr/bin:/bin",
            "PID": String(ProcessInfo.processInfo.processIdentifier),
            "LOCK": lockURL.path,
            "WAIT": String(Self.crashReportWait),
            "REPORTS": Self.crashReportsDirectory.path,
            "EXE": Bundle.main.executableURL?.lastPathComponent ?? "LinearMouse",
            "BUNDLE": Bundle.main.bundleIdentifier ?? "",
            "APP": Bundle.main.bundleURL.path
        ]

        if let size = try? guardianLogURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 64 * 1024 {
            try? FileManager.default.removeItem(at: guardianLogURL)
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // A session of its own, so whatever cleans up after the app when it
        // dies doesn't take the guardian with it.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, guardianLogURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)

        let argv = ["/bin/sh", "-c", script].map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }

        var pid: pid_t = 0
        let result = posix_spawn(&pid, "/bin/sh", &actions, &attributes, argv, envp)
        if result != 0 {
            os_log("Failed to start crash guardian: %{public}s", log: Self.log, type: .error, strerror(result))
        }
    }
}
