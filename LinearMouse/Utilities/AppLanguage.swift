// MIT License
// Copyright (c) 2021-2026 LinearMouse

import AppKit
import Foundation

/// Per-app language override, stored as `AppleLanguages` in the app's own
/// defaults domain. Takes effect after a restart.
enum AppLanguage {
    private static let key = "AppleLanguages"

    /// Localizations shipped in the bundle, sorted by their native names.
    static var available: [String] {
        Bundle.main.localizations
            .filter { $0 != "Base" }
            .sorted { displayName(of: $0).localizedCaseInsensitiveCompare(displayName(of: $1)) == .orderedAscending }
    }

    /// The overridden language, or nil when following the system.
    static var current: String? {
        guard let domain = Bundle.main.bundleIdentifier,
              let languages = UserDefaults.standard.persistentDomain(forName: domain)?[key] as? [String] else {
            return nil
        }
        return languages.first
    }

    static func set(_ language: String?) {
        if let language {
            UserDefaults.standard.set([language], forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    static func displayName(of language: String) -> String {
        let locale = Locale(identifier: language)
        return locale.localizedString(forIdentifier: language)?.localizedCapitalized ?? language
    }

    /// Relaunches the app once this instance has exited.
    static func relaunch() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = [
            "-c",
            "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.1; done; /usr/bin/open \"$0\" --args --show",
            Bundle.main.bundlePath
        ]
        try? task.run()
        NSApp.terminate(nil)
    }
}
