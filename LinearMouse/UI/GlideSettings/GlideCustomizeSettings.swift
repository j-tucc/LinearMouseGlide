// MIT License
// Copyright (c) 2021-2026 LinearMouse

import AppKit
import SwiftUI

struct GlideCustomizeSettings: View {
    @ObservedObject var glide = GlideState.shared

    @State private var selection: String?
    @State private var importResult: Int?

    private enum Column {
        static let speed: CGFloat = 220
        static let reverse: CGFloat = 80
        static let smooth: CGFloat = 80
    }

    var body: some View {
        DetailView(schemeSpecific: false) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(spacing: 0) {
                    header
                    Divider()
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(glide.appRules) { rule in
                                row(for: rule)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .frame(maxHeight: .infinity)
                }
                .padding(.horizontal, 8)
                .background(Color.primary.opacity(0.05))
                .cornerRadius(12)

                HStack(spacing: 8) {
                    Button(action: showAddMenu) {
                        Image("Plus").frame(width: 24, height: 16)
                    }
                    Button(action: removeSelected) {
                        Image("Minus").frame(width: 24, height: 16)
                    }
                    .disabled(selection == nil)

                    Text("If the program is missing, click the `+` button to add it manually")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    Spacer()

                    if GlideState.hasMouseGlidePreferences {
                        Button("Import from Mouse Glide") {
                            importResult = glide.importMouseGlidePreferences()
                        }
                    }
                }
            }
            .padding(24)
        }
        .alert(item: Binding(
            get: { importResult.map(ImportResult.init) },
            set: { importResult = $0?.count }
        )) { result in
            Alert(title: Text("Imported \(result.count) apps from Mouse Glide."))
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            Text("App").frame(maxWidth: .infinity)
            Divider().frame(height: 14)
            Text("Speed").frame(width: Column.speed)
            Divider().frame(height: 14)
            Text("Reverse").frame(width: Column.reverse)
            Divider().frame(height: 14)
            Text("Smooth").frame(width: Column.smooth)
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.vertical, 10)
    }

    private func row(for rule: GlideState.AppRule) -> some View {
        let app = try? readInstalledApp(bundleIdentifier: rule.bundleIdentifier)
        let isSelected = selection == rule.bundleIdentifier

        return HStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(nsImage: app?.bundleIcon ?? NSWorkspace.shared.icon(forFile: "/Applications"))
                    .resizable()
                    .frame(width: 22, height: 22)
                Text(app?.bundleName ?? rule.bundleIdentifier)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.leading, 8)
            .frame(maxWidth: .infinity)

            GlideSpeedSlider(speed: binding(for: rule, \.speed))
                .padding(.horizontal, 10)
                .frame(width: Column.speed)

            Toggle("Reverse", isOn: binding(for: rule, \.reverse))
                .labelsHidden()
                .frame(width: Column.reverse)

            Toggle("Smooth", isOn: binding(for: rule, \.smooth))
                .glideSwitch()
                .frame(width: Column.smooth)
        }
        .padding(.vertical, 4)
        .background(Color.accentColor.opacity(isSelected ? 0.25 : 0))
        .cornerRadius(6)
        .contentShape(Rectangle())
        .onTapGesture {
            selection = rule.bundleIdentifier
        }
    }

    private func binding<T>(
        for rule: GlideState.AppRule,
        _ keyPath: WritableKeyPath<GlideState.AppRule, T>
    ) -> Binding<T> {
        Binding(
            get: { rule[keyPath: keyPath] },
            set: { newValue in
                var rule = rule
                rule[keyPath: keyPath] = newValue
                glide.update(rule)
            }
        )
    }

    private func removeSelected() {
        guard let selection else {
            return
        }
        glide.removeApp(bundleIdentifier: selection)
        self.selection = nil
    }

    private func showAddMenu() {
        let menu = GlideAppMenu(excluding: Set(glide.appRules.map(\.bundleIdentifier))) { bundleIdentifier in
            glide.addApp(bundleIdentifier: bundleIdentifier)
            selection = bundleIdentifier
        }
        menu.popUpAtMouseLocation()
    }
}

private struct ImportResult: Identifiable {
    var id: Int {
        count
    }

    var count: Int
}

/// Running apps first, then a file picker for anything else.
private final class GlideAppMenu: NSObject {
    private let menu = NSMenu()
    private let onSelect: (String) -> Void

    init(excluding configured: Set<String>, onSelect: @escaping (String) -> Void) {
        self.onSelect = onSelect
        super.init()

        let header = NSMenuItem(title: NSLocalizedString("Running applications", comment: ""), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> (String, String, NSImage?)? in
                guard let bundleIdentifier = app.bundleIdentifier,
                      bundleIdentifier != Bundle.main.bundleIdentifier,
                      !configured.contains(bundleIdentifier) else {
                    return nil
                }
                return (bundleIdentifier, app.localizedName ?? bundleIdentifier, app.icon)
            }
            .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }

        for (bundleIdentifier, name, icon) in runningApps {
            let item = NSMenuItem(title: name, action: #selector(selectRunningApp(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = bundleIdentifier
            item.image = icon.map { icon in
                let image = icon.copy() as! NSImage
                image.size = NSSize(width: 16, height: 16)
                return image
            }
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let choose = NSMenuItem(
            title: NSLocalizedString("Installed applications", comment: "") + "…",
            action: #selector(chooseApp),
            keyEquivalent: ""
        )
        choose.target = self
        menu.addItem(choose)
    }

    func popUpAtMouseLocation() {
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc private func selectRunningApp(_ sender: NSMenuItem) {
        guard let bundleIdentifier = sender.representedObject as? String else {
            return
        }
        onSelect(bundleIdentifier)
    }

    @objc private func chooseApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedFileTypes = ["app"]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else {
            return
        }

        for url in panel.urls {
            if let bundleIdentifier = Bundle(url: url)?.bundleIdentifier {
                onSelect(bundleIdentifier)
            }
        }
    }
}
