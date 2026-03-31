import AppKit
import WindowPilotCore

// MARK: - PreviewView

/// Displays a captured window screenshot in the right pane of PilotPanel.
///
/// Lifecycle:
/// - `showPreview(image:)` converts a CGImage to NSImage and plays a fade-in
///   animation that gives the perception of "blur resolving to clear".
/// - `clearPreview()` releases the CGImage reference and returns to the
///   no-selection placeholder (critical for the QD-05 memory budget).
///
/// The image is displayed aspect-fit via NSImageView with
/// `.scaleProportionallyUpOrDown`.  Placeholder states are handled by a
/// centred label + SF Symbol icon layered on top of the (hidden) image view.
public class PreviewView: NSView {

    // MARK: - Subviews

    private let imageView: NSImageView = {
        let iv = NSImageView()
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.imageAlignment = .alignCenter
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.wantsLayer = true
        // Don't let the image expand the view beyond its container
        iv.setContentHuggingPriority(.defaultLow, for: .horizontal)
        iv.setContentHuggingPriority(.defaultLow, for: .vertical)
        iv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        iv.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return iv
    }()

    /// SF-Symbol icon shown in placeholder states.
    private let placeholderIcon: NSImageView = {
        let iv = NSImageView()
        iv.imageScaling = .scaleProportionallyDown
        iv.imageAlignment = .alignCenter
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.contentTintColor = NSColor.tertiaryLabelColor
        return iv
    }()

    private let placeholderLabel: NSTextField = {
        let tf = NSTextField(labelWithString: "")
        tf.alignment = .center
        tf.textColor = NSColor.secondaryLabelColor
        tf.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        tf.lineBreakMode = .byWordWrapping
        tf.maximumNumberOfLines = 3
        tf.translatesAutoresizingMaskIntoConstraints = false
        return tf
    }()

    // MARK: - Public state

    /// Set to `false` when Screen Recording permission has been denied.
    /// Affects which placeholder message is shown when `showPreview(image: nil)` is called.
    public var hasScreenRecordingPermission: Bool = true

    // MARK: - Init

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildLayout()
        showPlaceholder(message: "Select a window to preview")
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        buildLayout()
        showPlaceholder(message: "Select a window to preview")
    }

    // MARK: - Public API

    /// Display `image` in the view, animating from near-transparent to fully
    /// opaque to give a "blur resolving to clear" feel.
    ///
    /// Passing `nil` shows the appropriate placeholder instead.
    public func showPreview(image: CGImage?) {
        guard let cgImage = image else {
            let message = hasScreenRecordingPermission
                ? "Select a window to preview"
                : "Grant Screen Recording permission for previews"
            showPlaceholder(message: message)
            return
        }

        // Convert to NSImage using point-based size (not pixel-based)
        // CGImage dimensions are in pixels; divide by screen scale for proper points
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let size = NSSize(
            width: CGFloat(cgImage.width) / scale,
            height: CGFloat(cgImage.height) / scale
        )
        let nsImage = NSImage(cgImage: cgImage, size: size)

        // Swap to image view, hide placeholder
        hidePlaceholder()
        imageView.image = nsImage
        imageView.isHidden = false

        // Animate: start nearly transparent, fade to fully opaque
        animateFadeIn()
    }

    /// Release the current screenshot reference and return to the no-selection
    /// placeholder.  Call this when the panel is dismissed (QD-05).
    public func clearPreview() {
        // Remove any in-progress animation before mutating layer state
        imageView.layer?.removeAllAnimations()

        // Nil the image — this releases the backing CGImage
        imageView.image = nil
        imageView.isHidden = true

        showPlaceholder(message: "Select a window to preview")
    }

    // MARK: - Private helpers

    private func buildLayout() {
        // Image view — fills the PreviewView with padding
        addSubview(imageView)
        let pad: CGFloat = 12
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: topAnchor, constant: pad),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -pad),
        ])

        // Placeholder stack — centred icon above centred label
        let placeholderStack = NSStackView(views: [placeholderIcon, placeholderLabel])
        placeholderStack.orientation = .vertical
        placeholderStack.spacing = 10
        placeholderStack.alignment = .centerX
        placeholderStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholderStack)

        NSLayoutConstraint.activate([
            // Icon fixed size
            placeholderIcon.widthAnchor.constraint(equalToConstant: 48),
            placeholderIcon.heightAnchor.constraint(equalToConstant: 48),

            // Label width capped so long strings wrap gracefully
            placeholderLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 260),

            // Centre the stack in the available space
            placeholderStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholderStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private func showPlaceholder(message: String) {
        imageView.isHidden = true
        imageView.layer?.removeAllAnimations()

        // Choose icon based on context
        let symbolName: String
        if !hasScreenRecordingPermission {
            symbolName = "lock.shield"
        } else {
            symbolName = "photo.on.rectangle"
        }

        if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 40, weight: .thin)
            placeholderIcon.image = img.withSymbolConfiguration(cfg)
        }

        placeholderLabel.stringValue = message

        // Make placeholder visible
        placeholderIcon.isHidden = false
        placeholderLabel.isHidden = false
    }

    private func hidePlaceholder() {
        placeholderIcon.isHidden = true
        placeholderLabel.isHidden = true
    }

    /// Fade the image view from nearly transparent to opaque over ~300 ms.
    /// This gives the visual impression of a blurry image sharpening into focus
    /// without the complexity of a live CIFilter animation.
    private func animateFadeIn() {
        guard let layer = imageView.layer else {
            imageView.layer?.opacity = 1.0
            return
        }

        // Remove any previous animation first
        layer.removeAllAnimations()

        // Start at low opacity
        layer.opacity = 0.15

        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = Float(0.15)
        anim.toValue   = Float(1.0)
        anim.duration  = 0.3
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        anim.fillMode  = .forwards
        anim.isRemovedOnCompletion = false

        // Set the model-layer value so the final state persists after the
        // animation is cleaned up
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = 1.0
        CATransaction.commit()

        layer.add(anim, forKey: "fadeIn")
    }
}
