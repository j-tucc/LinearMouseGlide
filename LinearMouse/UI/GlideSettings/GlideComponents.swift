// MIT License
// Copyright (c) 2021-2026 LinearMouse

import AppKit
import SwiftUI

struct GlideSectionTitle: View {
    var title: LocalizedStringKey

    init(_ title: LocalizedStringKey) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.system(size: 15, weight: .medium))
            .padding(.leading, 2)
    }
}

/// A rounded group of rows separated by dividers.
struct GlideCard<Content: View>: View {
    var content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        VStack(spacing: 0) {
            content()
        }
        .padding(.horizontal, 16)
        .background(Color.primary.opacity(0.05))
        .cornerRadius(12)
    }
}

struct GlideRow<Accessory: View>: View {
    var title: LocalizedStringKey
    var subtitle: LocalizedStringKey
    var showsDivider = true
    var accessory: () -> Accessory

    init(
        _ title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        showsDivider: Bool = true,
        @ViewBuilder accessory: @escaping () -> Accessory
    ) {
        self.title = title
        self.subtitle = subtitle
        self.showsDivider = showsDivider
        self.accessory = accessory
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 14))
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 16)
                accessory()
            }
            .padding(.vertical, 14)

            if showsDivider {
                Divider()
            }
        }
    }
}

/// An `NSSlider` with one tick mark per step, like Mouse Glide's 1.0...5.0
/// speed slider, which SwiftUI's `Slider` cannot show on older systems.
struct GlideSpeedSlider: NSViewRepresentable {
    @Binding var speed: Double
    var range = Scheme.Scrolling.Glide.speedRange
    var step = Scheme.Scrolling.Glide.speedStep

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(
            value: speed,
            minValue: range.lowerBound,
            maxValue: range.upperBound,
            target: context.coordinator,
            action: #selector(Coordinator.valueChanged(_:))
        )
        slider.numberOfTickMarks = Int(((range.upperBound - range.lowerBound) / step).rounded()) + 1
        slider.allowsTickMarkValuesOnly = true
        slider.tickMarkPosition = .below
        slider.isContinuous = true
        slider.controlSize = .small
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.speed = $speed
        if slider.doubleValue != speed {
            slider.doubleValue = speed
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(speed: $speed)
    }

    final class Coordinator: NSObject {
        var speed: Binding<Double>

        init(speed: Binding<Double>) {
            self.speed = speed
        }

        @objc func valueChanged(_ sender: NSSlider) {
            guard sender.doubleValue != speed.wrappedValue else {
                return
            }
            speed.wrappedValue = sender.doubleValue
        }
    }
}

extension View {
    func glideSwitch() -> some View {
        toggleStyle(SwitchToggleStyle()).labelsHidden()
    }
}
