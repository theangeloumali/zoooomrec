import AppKit

/// One permission line in the onboarding window: a live status glyph, the permission
/// name, a one-line reason, and an action button shown only while the grant is missing.
///
/// AppKit rule: build and mutate on the main thread only. `NSStackView` collapses a
/// hidden arranged view automatically, so hiding the button when granted reclaims its
/// space without any manual layout.
final class PermissionRow: NSStackView {
  private let statusLabel = NSTextField(labelWithString: "❌")
  private let actionButton: NSButton
  private let action: () -> Void

  /// - Parameters:
  ///   - title: permission name (bold).
  ///   - detail: one-line reason it is needed (wraps).
  ///   - actionTitle: button label used while the grant is missing.
  ///   - action: invoked when the button is clicked.
  init(title: String, detail: String, actionTitle: String, action: @escaping () -> Void) {
    self.action = action
    actionButton = NSButton(title: actionTitle, target: nil, action: nil)
    super.init(frame: .zero)

    orientation = .horizontal
    alignment = .firstBaseline
    spacing = 12
    translatesAutoresizingMaskIntoConstraints = false

    statusLabel.font = .systemFont(ofSize: 15)
    statusLabel.alignment = .center
    statusLabel.setContentHuggingPriority(.required, for: .horizontal)
    statusLabel.widthAnchor.constraint(equalToConstant: 22).isActive = true

    let titleLabel = NSTextField(labelWithString: title)
    titleLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)

    let detailLabel = NSTextField(labelWithString: detail)
    detailLabel.lineBreakMode = .byWordWrapping
    detailLabel.maximumNumberOfLines = 0
    detailLabel.preferredMaxLayoutWidth = 260
    detailLabel.textColor = .secondaryLabelColor
    detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

    let textStack = NSStackView(views: [titleLabel, detailLabel])
    textStack.orientation = .vertical
    textStack.alignment = .leading
    textStack.spacing = 2
    textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)

    actionButton.target = self
    actionButton.action = #selector(performAction)
    actionButton.bezelStyle = .rounded
    actionButton.setContentHuggingPriority(.required, for: .horizontal)

    addView(statusLabel, in: .leading)
    addView(textStack, in: .leading)
    addView(actionButton, in: .trailing)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("PermissionRow is code-only") }

  /// Reconciles the glyph and button visibility with the current grant state.
  func update(granted: Bool) {
    statusLabel.stringValue = granted ? "✅" : "❌"
    statusLabel.setAccessibilityLabel(granted ? "granted" : "not granted")
    actionButton.isHidden = granted
  }

  @objc private func performAction() {
    action()
  }
}
