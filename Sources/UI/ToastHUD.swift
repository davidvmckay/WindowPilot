import AppKit

// MARK: - ToastHUD

/// Transient floating HUD for surfacing action failures
/// (e.g. "Couldn't focus window"). Auto-dismisses after a short delay.
/// Main-thread only.
public enum ToastHUD {

    private static var panel: NSPanel?
    private static var dismissWorkItem: DispatchWorkItem?

    /// Show a short message centered near the bottom of the cursor's screen.
    public static func show(_ message: String, duration: TimeInterval = 1.6) {
        dismissWorkItem?.cancel()
        panel?.orderOut(nil)

        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.sizeToFit()

        let hPad: CGFloat = 16
        let vPad: CGFloat = 10
        let size = NSSize(
            width: label.frame.width + hPad * 2,
            height: label.frame.height + vPad * 2
        )

        let hud = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        hud.level = .floating
        hud.isOpaque = false
        hud.backgroundColor = .clear
        hud.ignoresMouseEvents = true
        hud.isReleasedWhenClosed = false
        hud.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        label.setFrameOrigin(NSPoint(x: hPad, y: vPad))
        effect.addSubview(label)
        hud.contentView = effect

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) })
            ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        hud.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + visible.height * 0.15
        ))

        hud.orderFrontRegardless()
        panel = hud

        let work = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                hud.animator().alphaValue = 0
            }, completionHandler: {
                hud.orderOut(nil)
                hud.alphaValue = 1
                if panel === hud { panel = nil }
            })
        }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }
}
