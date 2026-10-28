// MIT License
// Copyright (c) 2021-2026 LinearMouse

import AppKit
import Combine
import Defaults
import Foundation

/// Mouse Glide style settings, stored as `scrolling.glide` in LinearMouse
/// schemes: global values in the "All Mice" (mouse category) scheme, and
/// per-app values in "All Mice" schemes conditioned on an app bundle
/// identifier. Device schemes don't set `glide`, so they never override it.
final class GlideState: ObservableObject {
    static let shared = GlideState()

    typealias Glide = Scheme.Scrolling.Glide

    struct AppRule: Identifiable, Equatable {
        var id: String {
            bundleIdentifier
        }

        var bundleIdentifier: String
        var speed: Double
        var reverse: Bool
        /// Mouse Glide's "Smooth" column: off excludes the app entirely.
        var smooth: Bool
    }

    private static let mouse = DeviceMatcher(category: .mouse)

    private let configurationState: ConfigurationState = .shared
    private var subscriptions = Set<AnyCancellable>()

    init() {
        configurationState.$configuration
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &subscriptions)
    }
}

// MARK: - Global settings

extension GlideState {
    private var globalGlide: Glide {
        scheme(forApp: nil).scrolling.glide
    }

    var reverse: Bool {
        get { globalGlide.isReversed }
        set { updateGlobal { $0.reverse = newValue } }
    }

    var speed: Double {
        get { globalGlide.resolvedSpeed }
        set { updateGlobal { $0.speed = Self.decimal(newValue) } }
    }

    /// Enables gliding for all mice the first time the app runs, with Mouse
    /// Glide's defaults (speed 2, no reverse). Later changes are left alone.
    func seedDefaultsIfNeeded() {
        guard !Defaults[.glideDefaultsSeeded] else {
            return
        }
        Defaults[.glideDefaultsSeeded] = true

        guard scheme(forApp: nil).scrolling.$glide == nil else {
            return
        }

        updateScheme(forApp: nil) { scheme in
            scheme.scrolling.glide = Glide(enabled: true, speed: Glide.defaultSpeed, reverse: false)
        }
    }

    private func updateGlobal(_ body: (inout Glide) -> Void) {
        updateScheme(forApp: nil) { scheme in
            var glide = scheme.scrolling.glide
            if glide.enabled == nil {
                glide.enabled = true
            }
            body(&glide)
            scheme.scrolling.glide = glide
        }
    }

    private static func decimal(_ value: Double) -> Decimal {
        let stepped = (value / Glide.speedStep).rounded() * Glide.speedStep
        return Decimal(stepped.clamped(to: Glide.speedRange))
    }
}

// MARK: - Per-app rules

extension GlideState {
    var appRules: [AppRule] {
        let global = globalGlide

        return configurationState.configuration.schemes
            .allDeviceCategorySpecificSchemes(of: .mouse)
            .compactMap { _, scheme -> AppRule? in
                guard let condition = scheme.if?.first,
                      let app = condition.app,
                      condition.display == nil,
                      condition.processPath == nil,
                      condition.processName == nil,
                      let glide = scheme.scrolling.$glide else {
                    return nil
                }

                return AppRule(
                    bundleIdentifier: app,
                    speed: (glide.speed ?? global.speed ?? Glide.defaultSpeed).asTruncatedDouble,
                    reverse: glide.reverse ?? global.isReversed,
                    smooth: glide.enabled ?? global.isEnabled
                )
            }
    }

    func addApp(bundleIdentifier: String) {
        guard !appRules.contains(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            return
        }

        update(AppRule(bundleIdentifier: bundleIdentifier, speed: speed, reverse: reverse, smooth: true))
    }

    func update(_ rule: AppRule) {
        updateScheme(forApp: rule.bundleIdentifier) { scheme in
            scheme.scrolling.glide = Glide(
                enabled: rule.smooth,
                speed: Self.decimal(rule.speed),
                reverse: rule.reverse
            )
        }
    }

    /// Removes the glide settings for an app, and the whole scheme if
    /// nothing else (pointer, buttons…) was configured for it.
    func removeApp(bundleIdentifier: String) {
        var schemes = configurationState.configuration.schemes
        guard case let .at(index) = schemes.schemeIndex(
            ofDeviceCategory: .mouse,
            ofApp: bundleIdentifier,
            ofProcessPath: nil,
            ofProcessName: nil,
            ofDisplay: nil
        ) else {
            return
        }

        var scheme = schemes[index]
        scheme.scrolling.$glide = nil
        if scheme.scrolling == Scheme.Scrolling() {
            scheme.$scrolling = nil
        }

        if scheme.$scrolling == nil, scheme.$pointer == nil, scheme.$buttons == nil, scheme.$logitech == nil {
            schemes.remove(at: index)
        } else {
            schemes[index] = scheme
        }
        configurationState.configuration.schemes = schemes
    }
}

// MARK: - Mouse Glide import

extension GlideState {
    static var mouseGlidePreferencesURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Containers/com.tinfine.MouseGlide/Data/Library/Preferences/com.tinfine.MouseGlide.plist"
            )
    }

    static var hasMouseGlidePreferences: Bool {
        FileManager.default.fileExists(atPath: mouseGlidePreferencesURL.path)
    }

    private struct MouseGlideApp: Decodable {
        var path: String
        var speed: Double?
        var reverse: Bool?
        var smooth: Bool?
    }

    /// Imports Mouse Glide's settings. Its `speedKey` (default 2.0) and
    /// `isReverseKey` (default false) are only stored once changed, so their
    /// defaults apply when absent. Returns the number of apps imported.
    @discardableResult
    func importMouseGlidePreferences() -> Int {
        guard let preferences = NSDictionary(contentsOf: Self.mouseGlidePreferencesURL) as? [String: Any] else {
            return 0
        }

        speed = (preferences["speedKey"] as? Double) ?? Glide.defaultSpeed.asTruncatedDouble
        reverse = (preferences["isReverseKey"] as? Bool) ?? false

        guard let json = (preferences["appsKey"] as? String)?.data(using: .utf8),
              let apps = try? JSONDecoder().decode([MouseGlideApp].self, from: json) else {
            return 0
        }

        var imported = 0
        for app in apps {
            guard let bundleIdentifier = Bundle(path: app.path)?.bundleIdentifier else {
                continue
            }
            update(AppRule(
                bundleIdentifier: bundleIdentifier,
                speed: app.speed ?? speed,
                reverse: app.reverse ?? false,
                smooth: app.smooth ?? true
            ))
            imported += 1
        }
        return imported
    }
}

// MARK: - Scheme helpers

extension GlideState {
    private func scheme(forApp app: String?) -> Scheme {
        let schemes = configurationState.configuration.schemes
        if case let .at(index) = schemes.schemeIndex(
            ofDeviceCategory: .mouse,
            ofApp: app,
            ofProcessPath: nil,
            ofProcessName: nil,
            ofDisplay: nil
        ) {
            return schemes[index]
        }

        return Scheme(if: [.init(device: Self.mouse, app: app)])
    }

    private func updateScheme(forApp app: String?, _ body: (inout Scheme) -> Void) {
        var schemes = configurationState.configuration.schemes
        switch schemes.schemeIndex(
            ofDeviceCategory: .mouse,
            ofApp: app,
            ofProcessPath: nil,
            ofProcessName: nil,
            ofDisplay: nil
        ) {
        case let .at(index):
            body(&schemes[index])
        case let .insertAt(index):
            var scheme = Scheme(if: [.init(device: Self.mouse, app: app)])
            body(&scheme)
            schemes.insert(scheme, at: index)
        }
        configurationState.configuration.schemes = schemes
    }
}
