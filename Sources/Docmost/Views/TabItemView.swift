import AppKit

// A single server tab drawn as a browser-style tab: rounded top corners and a
// flush bottom. The selected tab fills with the content background and covers the
// bar's bottom hairline, so it appears attached to the content area below.
final class TabItemView: NSView {

    var onClick: (() -> Void)?
    // Fired when the trailing close (×) button is clicked (only when shown).
    var onClose: (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    private var isSelectedTab = false
    private var isHovered = false
    private var trackingArea: NSTrackingArea?

    private let cornerRadius: CGFloat = 7
    private let horizontalPadding: CGFloat = 14
    // Width reserved for the close button and the gap before it when it is shown.
    private let closeButtonWidth: CGFloat = 16
    private let closeButtonGap: CGFloat = 4

    // The trailing close button, hidden by default (server tabs never show it).
    private let closeButton = NSButton()
    // Two mutually-exclusive label-trailing constraints: one to the view edge (no close
    // button) and one to the close button's leading edge (close button shown).
    private var labelTrailingToEdge: NSLayoutConstraint!
    private var labelTrailingToButton: NSLayoutConstraint!

    // When true, a trailing × button is shown and the label leaves room for it. Server tabs
    // keep the default (false) so they look exactly as before.
    var showsCloseButton: Bool = false {
        didSet { applyCloseButtonVisibility() }
    }

    init(title: String) {
        super.init(frame: .zero)
        wantsLayer = true

        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)

        // Borderless × button pinned to the trailing edge; hidden unless showsCloseButton.
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")
        closeButton.isBordered = false
        closeButton.bezelStyle = .regularSquare
        closeButton.imagePosition = .imageOnly
        closeButton.controlSize = .small
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.isHidden = true
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)

        labelTrailingToEdge = label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -horizontalPadding)
        labelTrailingToButton = label.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -closeButtonGap)

        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: horizontalPadding),
            labelTrailingToEdge,

            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            closeButton.widthAnchor.constraint(equalToConstant: closeButtonWidth),
            closeButton.heightAnchor.constraint(equalToConstant: closeButtonWidth),
        ])

        label.stringValue = title
        updateLabelStyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var title: String {
        get { label.stringValue }
        set {
            label.stringValue = newValue
            invalidateIntrinsicContentSize()
        }
    }

    func setSelected(_ selected: Bool) {
        guard isSelectedTab != selected else { return }
        isSelectedTab = selected
        if selected { isHovered = false }
        updateLabelStyle()
        needsDisplay = true
    }

    // Width fits the label (clamped); height is driven by the bar via a constraint.
    // When the close button is shown, reserve room for it so the title isn't over-truncated.
    override var intrinsicContentSize: NSSize {
        var width = label.intrinsicContentSize.width + horizontalPadding * 2
        if showsCloseButton {
            width += closeButtonWidth + closeButtonGap
        }
        return NSSize(width: min(max(width, 80), 220), height: NSView.noIntrinsicMetric)
    }

    // Toggle the close button's visibility and the label's trailing constraint so the title
    // truncates before the × when shown, and the view looks identical to before when hidden.
    private func applyCloseButtonVisibility() {
        closeButton.isHidden = !showsCloseButton
        if showsCloseButton {
            labelTrailingToEdge.isActive = false
            labelTrailingToButton.isActive = true
        } else {
            labelTrailingToButton.isActive = false
            labelTrailingToEdge.isActive = true
        }
        invalidateIntrinsicContentSize()
    }

    @objc private func closeClicked() {
        onClose?()
    }

    private func updateLabelStyle() {
        label.textColor = isSelectedTab ? .labelColor : .secondaryLabelColor
        let weight: NSFont.Weight = isSelectedTab ? .semibold : .regular
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: weight)
    }

    // MARK: - Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard !isSelectedTab else { return }
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    // Repaint with theme-appropriate colors when the system appearance changes;
    // layer-backed drawing caches its content otherwise.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: - Drawing (non-flipped: origin bottom-left, top = maxY)

    // Outline of the tab: up the left side, around the rounded top, down the right
    // side. `closed` adds the bottom edge (for filling); leave open for stroking so
    // the bottom hairline is not drawn.
    private func tabPath(closed: Bool) -> NSBezierPath {
        let r = cornerRadius
        let b = bounds
        let path = NSBezierPath()
        path.move(to: NSPoint(x: b.minX, y: b.minY))
        path.line(to: NSPoint(x: b.minX, y: b.maxY - r))
        path.appendArc(withCenter: NSPoint(x: b.minX + r, y: b.maxY - r),
                       radius: r, startAngle: 180, endAngle: 90, clockwise: true)
        path.line(to: NSPoint(x: b.maxX - r, y: b.maxY))
        path.appendArc(withCenter: NSPoint(x: b.maxX - r, y: b.maxY - r),
                       radius: r, startAngle: 90, endAngle: 0, clockwise: true)
        path.line(to: NSPoint(x: b.maxX, y: b.minY))
        if closed { path.close() }
        return path
    }

    override func draw(_ dirtyRect: NSRect) {
        if isSelectedTab {
            NSColor.controlBackgroundColor.setFill()
            tabPath(closed: true).fill()
            // Hairline around the top + sides (not the bottom) for definition.
            let outline = tabPath(closed: false)
            outline.lineWidth = 1
            NSColor.separatorColor.setStroke()
            outline.stroke()
        } else if isHovered {
            let rect = NSRect(x: bounds.minX + 3, y: bounds.minY + 4,
                              width: bounds.width - 6, height: bounds.height - 4)
            let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
            NSColor.labelColor.withAlphaComponent(0.07).setFill()
            path.fill()
        }
    }
}
