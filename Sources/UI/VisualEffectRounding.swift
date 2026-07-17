import AppKit

extension NSVisualEffectView {
    /// Round both the layer (border/content clip) and the blur material.
    /// NSVisualEffectView does not clip its material to the layer's corner
    /// radius — the square material corners bleed past rounded borders as
    /// faint right-angle lines, most visible against light backgrounds. The
    /// resizable mask image clips the material (and the window's alpha-derived
    /// shadow) to the same rounded rect the layer draws. No-op when the
    /// current mask already has this radius.
    public func applyRoundedCorners(radius: CGFloat) {
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.masksToBounds = true
        // The mask's uniform capInsets equal its radius — reuse as identity.
        if let mask = maskImage, mask.capInsets.top == radius { return }
        let side = radius * 2 + 2
        let mask = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        mask.resizingMode = .stretch
        maskImage = mask
    }
}
