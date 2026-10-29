// MIT License
// Copyright (c) 2021-2026 LinearMouse

import Foundation

extension Scheme.Scrolling {
    /// Mouse Glide style smoothing. It runs after every other scrolling
    /// setting, on the already reversed / distance-adjusted wheel events.
    struct Glide: Equatable, Codable, ImplicitInitable {
        /// `false` excludes the matching app: its events pass through untouched.
        var enabled: Bool?
        /// Multiplier on the per-notch glide distance, 1.0...5.0 in 0.5 steps.
        var speed: Decimal?
        /// Reverses direction on top of `scrolling.reverse`.
        var reverse: Bool?
        /// Extra multiplier for leftward side/tilt wheel input, 1.0...3.0, to
        /// make up for a side wheel that is harder to turn one way.
        var leftMultiplier: Decimal?

        init() {}

        init(enabled: Bool? = nil, speed: Decimal? = nil, reverse: Bool? = nil, leftMultiplier: Decimal? = nil) {
            self.enabled = enabled
            self.speed = speed
            self.reverse = reverse
            self.leftMultiplier = leftMultiplier
        }
    }
}

extension Scheme.Scrolling.Glide {
    static let speedRange: ClosedRange<Double> = 1 ... 5
    static let speedStep = 0.5
    static let defaultSpeed: Decimal = 2
    static let leftMultiplierRange: ClosedRange<Double> = 1 ... 3
    static let leftMultiplierStep = 0.1

    var isEnabled: Bool {
        enabled ?? false
    }

    var resolvedSpeed: Double {
        (speed ?? Self.defaultSpeed).asTruncatedDouble.clamped(to: Self.speedRange)
    }

    var isReversed: Bool {
        reverse ?? false
    }

    var resolvedLeftMultiplier: Double {
        (leftMultiplier ?? 1).asTruncatedDouble.clamped(to: Self.leftMultiplierRange)
    }

    func merge(into glide: inout Self) {
        if let enabled {
            glide.enabled = enabled
        }

        if let speed {
            glide.speed = speed
        }

        if let reverse {
            glide.reverse = reverse
        }

        if let leftMultiplier {
            glide.leftMultiplier = leftMultiplier
        }
    }

    func merge(into glide: inout Self?) {
        if glide == nil {
            glide = Self()
        }

        merge(into: &glide!)
    }
}
