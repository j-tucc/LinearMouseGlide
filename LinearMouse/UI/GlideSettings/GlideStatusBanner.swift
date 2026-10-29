// MIT License
// Copyright (c) 2021-2026 LinearMouse

import AppKit
import SwiftUI

/// Whether Glide is really gliding right now, and what went wrong last.
struct GlideStatusBanner: View {
    @ObservedObject var health = GlideHealth.shared

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    var body: some View {
        GlideCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle()
                        .fill(indicatorColor)
                        .frame(width: 9, height: 9)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.system(size: 14, weight: .medium))
                        Text(detail)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let incident = health.lastIncident, health.status == .active {
                    Text(String(
                        format: NSLocalizedString("Last problem: %@ Fixed itself at %@.", comment: ""),
                        incident.reason,
                        Self.timeFormatter.string(from: incident.recoveredAt)
                    ))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 17)
                }

                if let crash = health.crashNotice {
                    HStack(spacing: 12) {
                        Text(crashText(crash))
                            .font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        if let reportURL = crash.reportURL {
                            Button("Show Crash Report") {
                                NSWorkspace.shared.open(reportURL)
                            }
                            .controlSize(.small)
                        }
                    }
                    .padding(.leading, 17)
                }
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var indicatorColor: Color {
        switch health.status {
        case .active:
            return .green
        case .off:
            return .gray
        case .degraded:
            return .orange
        }
    }

    private var title: String {
        switch health.status {
        case .active:
            return NSLocalizedString("Glide is on", comment: "")
        case .off:
            return NSLocalizedString("Glide is off", comment: "")
        case .degraded:
            return NSLocalizedString("Glide is paused", comment: "")
        }
    }

    private var detail: String {
        switch health.status {
        case .active:
            return NSLocalizedString("Mouse wheel scrolling is being smoothed.", comment: "")
        case .off:
            return NSLocalizedString("Mouse wheel scrolling is not smoothed.", comment: "")
        case let .degraded(reason):
            return String(
                format: NSLocalizedString(
                    "%@ Scrolling still works, without smoothing. LinearMouse Glide is trying to restore it.",
                    comment: ""
                ),
                reason
            )
        }
    }

    private func crashText(_ crash: GlideHealth.CrashNotice) -> String {
        let date = Self.dateTimeFormatter.string(from: crash.date)
        if crash.restartedAutomatically {
            return String(format: NSLocalizedString("Crashed %@ and restarted itself.", comment: ""), date)
        }
        return String(format: NSLocalizedString("Crashed %@.", comment: ""), date)
    }
}
