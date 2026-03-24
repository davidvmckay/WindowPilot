import AppKit
import ApplicationServices
import CoreGraphics

enum Permissions {

    /// Checks whether the app has Accessibility permission.
    ///
    /// If the check fails, presents a modal NSAlert asking the user to grant
    /// access in System Settings. The panel cannot focus other windows without
    /// this permission, so the alert is blocking.
    ///
    /// - Returns: `true` if `AXIsProcessTrusted()` reports the app is trusted.
    @discardableResult
    static func checkAccessibility() -> Bool {
        let trusted = AXIsProcessTrusted()

        if !trusted {
            let alert = NSAlert()
            alert.messageText = "Accessibility Access Required"
            alert.informativeText = """
                WindowPilot needs Accessibility permission to bring windows \
                to the front and make them key. Without it, the Focus action \
                will not work.

                Click "Open System Settings" and enable WindowPilot under \
                Privacy & Security > Accessibility, then relaunch the app.
                """
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Not Now")

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                NSWorkspace.shared.open(
                    URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                )
            }
        }

        return trusted
    }

    /// Checks whether the app has Screen Recording permission.
    ///
    /// If not granted, triggers the system permission prompt via
    /// `CGRequestScreenCaptureAccess()` and shows an alert explaining why
    /// window titles and previews need this permission.
    ///
    /// - Returns: `true` if `CGPreflightScreenCaptureAccess()` returns `true`.
    @discardableResult
    static func checkScreenRecording() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }

        // Trigger the system permission prompt
        CGRequestScreenCaptureAccess()

        let alert = NSAlert()
        alert.messageText = "Screen Recording Permission Recommended"
        alert.informativeText = """
            WindowPilot needs Screen Recording permission to show window \
            titles and screenshot previews. Without it, all windows will \
            display as "Untitled" and previews will be unavailable.

            If the system prompt appeared, please allow access and relaunch \
            the app. Otherwise, go to System Settings > Privacy & Security > \
            Screen Recording and enable WindowPilot.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Continue Without")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
            )
        }

        return CGPreflightScreenCaptureAccess()
    }
}
