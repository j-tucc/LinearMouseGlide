// MIT License
// Copyright (c) 2021-2026 LinearMouse

import Foundation
import os.log

/// Debug-only fault injection for Glide's failure handling, driven by the
/// parity harness (`run.sh faults`) through a distributed notification:
///
///   stall-frames    display frames stop arriving (until `clear`)
///   fail-link       the frame source cannot be created (until `clear`)
///   invalidate-tap  Glide's event tap is invalidated once
///   crash           the app crashes
///   clear           undo stall-frames and fail-link
///
/// Release builds never listen, and every flag stays false.
final class GlideFaults {
    static let shared = GlideFaults()

    static let notificationName = Notification.Name("app.linearmouseglide.debug.fault")

    private static let log = OSLog(subsystem: Bundle.main.bundleIdentifier!, category: "GlideFaults")

    private var lock = os_unfair_lock()
    private var _stallFrames = false
    private var _failLink = false

    var stallFrames: Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return _stallFrames
    }

    var failLink: Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return _failLink
    }

    var onInvalidateTap: (() -> Void)?

    func listen() {
        #if DEBUG
            DistributedNotificationCenter.default().addObserver(
                forName: Self.notificationName,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let fault = notification.object as? String else {
                    return
                }
                self?.inject(fault)
            }
        #endif
    }

    private func inject(_ fault: String) {
        os_log("Injecting Glide fault: %{public}@", log: Self.log, type: .info, fault)
        os_unfair_lock_lock(&lock)
        switch fault {
        case "stall-frames":
            _stallFrames = true
        case "fail-link":
            _failLink = true
        case "clear":
            _stallFrames = false
            _failLink = false
        default:
            break
        }
        os_unfair_lock_unlock(&lock)

        switch fault {
        case "fail-link":
            GlideScrollingEngine.shared.dropDisplayLink()
        case "invalidate-tap":
            onInvalidateTap?()
        case "crash":
            fatalError("Glide fault injection: crash")
        default:
            break
        }
    }
}
