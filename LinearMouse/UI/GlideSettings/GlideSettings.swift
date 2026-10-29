// MIT License
// Copyright (c) 2021-2026 LinearMouse

import Defaults
import LaunchAtLogin
import SwiftUI

struct GlideSettings: View {
    @Default(.glideEnabled) var glideEnabled
    @ObservedObject var glide = GlideState.shared

    @State private var language = AppLanguage.current
    @State private var showsRestartAlert = false

    private static let systemLanguageTag = ""

    var body: some View {
        DetailView(schemeSpecific: false) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    GlideSectionTitle("Launch & Show")
                    GlideCard {
                        GlideRow("Enable Glide", subtitle: "Turn on the functions of the app") {
                            Toggle("Enable Glide", isOn: $glideEnabled)
                                .glideSwitch()
                        }

                        GlideRow("Launch at Login", subtitle: "Automatically launch app on login") {
                            LaunchAtLogin.Toggle {
                                Text("Launch at Login")
                            }
                            .glideSwitch()
                        }

                        GlideRow("Language", subtitle: "Change app language", showsDivider: false) {
                            languagePicker
                        }
                    }

                    GlideSectionTitle("Scroll Settings")
                        .padding(.top, 12)
                    GlideCard {
                        GlideRow("Reverse Scroll", subtitle: "Reverse the mouse wheel scroll direction") {
                            Toggle("Reverse Scroll", isOn: $glide.reverse)
                                .glideSwitch()
                        }

                        GlideRow("Scroll Speed", subtitle: "Mouse scroll speed") {
                            VStack(spacing: 2) {
                                GlideSpeedSlider(speed: $glide.speed)
                                HStack {
                                    Text("slow")
                                    Spacer()
                                    Text("quick")
                                }
                                .font(.system(size: 12))
                            }
                            .frame(width: 240)
                        }

                        GlideRow(
                            "Side Wheel Left Boost",
                            subtitle: "Extra speed when turning the side wheel left",
                            showsDivider: false
                        ) {
                            VStack(spacing: 2) {
                                GlideSpeedSlider(
                                    speed: $glide.leftMultiplier,
                                    range: Scheme.Scrolling.Glide.leftMultiplierRange,
                                    step: Scheme.Scrolling.Glide.leftMultiplierStep
                                )
                                HStack {
                                    Text(verbatim: "1×")
                                    Spacer()
                                    Text(verbatim: String(format: "%.1f×", glide.leftMultiplier))
                                        .fontWeight(.medium)
                                    Spacer()
                                    Text(verbatim: "3×")
                                }
                                .font(.system(size: 12))
                            }
                            .frame(width: 240)
                        }
                    }
                    .opacity(glideEnabled ? 1 : 0.5)

                    Button(action: runInBackground) {
                        Text("Run in the background")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.accentColor)
                            .cornerRadius(20)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .padding(.top, 20)
                }
                .padding(24)
            }
        }
        .alert(isPresented: $showsRestartAlert) {
            Alert(
                title: Text("Language Changed"),
                message: Text("The change will take effect after a restart. You can restart now or later."),
                primaryButton: .default(Text("Restart"), action: AppLanguage.relaunch),
                secondaryButton: .cancel(Text("Later"))
            )
        }
    }

    private var languagePicker: some View {
        let selection = Binding<String>(
            get: { language ?? Self.systemLanguageTag },
            set: { newValue in
                let newLanguage = newValue == Self.systemLanguageTag ? nil : newValue
                guard newLanguage != language else {
                    return
                }
                language = newLanguage
                AppLanguage.set(newLanguage)
                showsRestartAlert = true
            }
        )

        return Picker("Language", selection: selection) {
            Text("System").tag(Self.systemLanguageTag)
            ForEach(AppLanguage.available, id: \.self) { language in
                Text(verbatim: AppLanguage.displayName(of: language)).tag(language)
            }
        }
        .labelsHidden()
        .frame(width: 200)
    }

    private func runInBackground() {
        SettingsWindowController.shared.window?.performClose(nil)
    }
}
