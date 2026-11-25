import AppKit
import VagrantCore

/// Shows the log of the latest action on one machine, and lets the user answer
/// the command's prompts (sudo's password for NFS exports, `[y/N]` questions, ...).
@MainActor
final class LogWindowController: NSWindowController, NSWindowDelegate {
    /// Called with the typed text, without the trailing newline.
    var onSend: ((String) -> Void)?
    var onStop: (() -> Void)?

    private let commandLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let textView: NSTextView
    private let scrollView: NSScrollView
    private let promptLabel = NSTextField(labelWithString: "")
    private let plainField = NSTextField()
    private let secureField = NSSecureTextField()
    private let hideTyping = NSButton(checkboxWithTitle: "Hide typing", target: nil, action: nil)
    private let sendButton = NSButton(title: "Send", target: nil, action: nil)
    private let stopButton = NSButton(title: "Stop", target: nil, action: nil)
    private var shownText = ""

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()

    init(machineName: String) {
        scrollView = NSTextView.scrollableTextView()
        textView = scrollView.documentView as! NSTextView

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "\(machineName) — Log"
        window.minSize = NSSize(width: 420, height: 260)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("LogWindow")
        if window.frame.origin == .zero { window.center() }
        super.init(window: window)
        window.delegate = self
        buildContent(in: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(focusInput: Bool = false) {
        // Accessory apps aren't frontmost; activate so the window isn't hidden behind other apps.
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        if focusInput { window?.makeFirstResponder(activeField) }
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func update(_ log: ActionLog) {
        commandLabel.stringValue = log.command
        statusLabel.stringValue = "Started \(Self.timeFormatter.string(from: log.startedAt)) — \(log.statusDescription)"
        statusLabel.textColor = switch log.status {
        case .running, .exited(0), .stopped: .secondaryLabelColor
        default: .systemRed
        }

        if log.text != shownText {
            let clip = scrollView.contentView
            let atBottom = clip.bounds.maxY >= textView.frame.maxY - 20
            let storage = textView.textStorage!
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
                .foregroundColor: NSColor.textColor,
            ]
            if log.text.hasPrefix(shownText) {
                // Most updates only add output: append instead of re-laying out the whole log.
                storage.append(NSAttributedString(string: String(log.text.dropFirst(shownText.count)),
                                                  attributes: attributes))
            } else {
                storage.setAttributedString(NSAttributedString(string: log.text, attributes: attributes))
            }
            shownText = log.text
            if atBottom { textView.scrollToEndOfDocument(nil) }
        }

        let running = log.status == .running
        [plainField, secureField, hideTyping, sendButton, stopButton].forEach { $0.isEnabled = running }
        if !running { setPrompt(nil) }
    }

    /// Shows the question the command is waiting on, and hides typing for passwords.
    func setPrompt(_ prompt: Prompt?) {
        promptLabel.stringValue = prompt.map { "Waiting for input: \($0.line)" } ?? ""
        promptLabel.isHidden = prompt == nil
        if case .password = prompt {
            hideTyping.state = .on
            hideTypingChanged()
        }
    }

    // MARK: - Layout

    private var activeField: NSTextField { hideTyping.state == .on ? secureField : plainField }

    private func buildContent(in window: NSWindow) {
        commandLabel.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        commandLabel.lineBreakMode = .byTruncatingMiddle
        commandLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        textView.isEditable = false
        textView.isRichText = false
        textView.textContainerInset = NSSize(width: 6, height: 6)
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true

        promptLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        promptLabel.textColor = .systemOrange
        promptLabel.lineBreakMode = .byTruncatingTail
        promptLabel.isHidden = true
        promptLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Return reaches Send as the default button; the fields get no action of their own,
        // which would send the same answer twice.
        for field in [plainField, secureField] {
            field.placeholderString = "Type a response for the command and press Return"
        }
        secureField.isHidden = true
        hideTyping.target = self
        hideTyping.action = #selector(hideTypingChanged)
        sendButton.target = self
        sendButton.action = #selector(sendClicked)
        sendButton.keyEquivalent = "\r"
        stopButton.target = self
        stopButton.action = #selector(stopClicked)
        stopButton.toolTip = "Stop the running command"

        // The plain and secure fields share a slot; only one is visible at a time.
        let fieldSlot = NSView()
        for field in [plainField, secureField] {
            field.translatesAutoresizingMaskIntoConstraints = false
            fieldSlot.addSubview(field)
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: fieldSlot.leadingAnchor),
                field.trailingAnchor.constraint(equalTo: fieldSlot.trailingAnchor),
                field.topAnchor.constraint(equalTo: fieldSlot.topAnchor),
                field.bottomAnchor.constraint(equalTo: fieldSlot.bottomAnchor),
            ])
        }
        fieldSlot.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let header = NSStackView(views: [commandLabel, statusLabel])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 2

        let inputRow = NSStackView(views: [fieldSlot, hideTyping, sendButton, stopButton])
        inputRow.orientation = .horizontal
        inputRow.spacing = 8

        let stack = NSStackView(views: [header, scrollView, promptLabel, inputRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in [scrollView, inputRow] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        }
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
    }

    // MARK: - Actions

    @objc private func hideTypingChanged() {
        let hide = hideTyping.state == .on
        let (from, to): (NSTextField, NSTextField) = hide ? (plainField, secureField) : (secureField, plainField)
        guard to.isHidden else { return }
        to.stringValue = from.stringValue
        from.stringValue = ""
        from.isHidden = true
        to.isHidden = false
        if window?.isKeyWindow == true { window?.makeFirstResponder(to) }
    }

    @objc private func sendClicked() {
        let field = activeField
        guard field.isEnabled else { return }
        onSend?(field.stringValue)
        field.stringValue = ""
        // Each answer gets its own decision: the next question may not be a password.
        promptLabel.isHidden = true
        if hideTyping.state == .on {
            hideTyping.state = .off
            hideTypingChanged()
        }
        window?.makeFirstResponder(activeField)
    }

    @objc private func stopClicked() { onStop?() }
}
