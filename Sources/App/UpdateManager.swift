import AppKit
import Sparkle

// MARK: - UpdateManager

/// Thin wrapper around Sparkle's standard updater. App-layer only —
/// Core/ stays free of update logic.
///
/// Sparkle needs a real .app bundle (Info.plist with SUFeedURL and
/// SUPublicEDKey). When running the bare SPM executable during development
/// there is no bundle, so the updater stays disabled.
final class UpdateManager {

    private var controller: SPUStandardUpdaterController?

    var isAvailable: Bool { controller != nil }

    init() {
        guard Bundle.main.bundleIdentifier != nil else {
            print("[WP] UpdateManager: no app bundle — updater disabled (dev run)")
            return
        }
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    /// User-initiated check — Sparkle shows its own UI, including errors.
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
