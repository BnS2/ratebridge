// The setup flow: what ratebridge is, then the three things it cannot do for you,
// one at a time.
//
// This exists because `install.sh` prints those three steps to a terminal, and
// there is now a distribution path with no terminal in it at all — a release zip
// dragged to /Applications. That user gets a menu bar icon, no Accessibility
// grant, and a ⚠ with nothing to click. The installer's postamble was the only
// place the setup instructions lived, and it was the one place half the users
// would never look.
//
// Stepped rather than a single page. All three steps at once reads as a wall of
// things you have failed to do, and the one that actually matters — Accessibility
// — is a trip to System Settings that people abandon halfway. One decision per
// screen, each with the reason attached, and Continue always available because a
// step someone chooses to skip is not an error.
//
// Every step still reads live state on a timer rather than a snapshot, so this is
// the troubleshooting screen too: reopen it from the menu at any point and it
// says what is true now. That is the same principle the rest of the tool follows
// — every tier says what it saw and why — applied to the one surface that had
// nothing.
//
// It covers only what the CLI cannot reach: a TCC grant needs a click in System
// Settings, and a login item needs SMAppService. Rules, priority, idle rates and
// routing stay in `ratebridge config` and friends, which remain the source of
// truth.

import AppKit
import ServiceManagement

/// The row of dots under the flow. One per page, the current one accented, pages
/// already passed dimmer than pages still ahead — so it reads as progress rather
/// than as decoration.
private final class StepDots: NSStackView {
    private var circles: [NSView] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        orientation = .horizontal
        alignment = .centerY
        spacing = 7
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func update(current: Int, total: Int) {
        if circles.count != total {
            for circle in circles {
                removeArrangedSubview(circle)
                circle.removeFromSuperview()
            }
            circles = (0..<total).map { _ in
                let dot = NSView()
                dot.wantsLayer = true
                dot.layer?.cornerRadius = 4
                dot.translatesAutoresizingMaskIntoConstraints = false
                dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
                dot.heightAnchor.constraint(equalToConstant: 8).isActive = true
                addArrangedSubview(dot)
                return dot
            }
        }
        for (index, dot) in circles.enumerated() {
            let colour: NSColor = index == current ? .controlAccentColor
                                : index < current ? .tertiaryLabelColor
                                                  : .quaternaryLabelColor
            dot.layer?.backgroundColor = colour.cgColor
        }
    }
}

enum SetupStep: Int, CaseIterable {
    case welcome, accessibility, device, login, done

    /// Steps that represent something the user must actually do. `welcome` and
    /// `done` are framing, and counting them in "step 2 of 5" would overstate
    /// how much work this is.
    static var actionable: [SetupStep] { [.accessibility, .device, .login] }
}

final class SetupWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SetupWindowController()

    /// Set once the user has finished the flow, or asked not to be shown it
    /// again. Only suppresses the *automatic* open; `Setup…` in the menu always
    /// works, since this doubles as the troubleshooting screen.
    private static let suppressKey = "setupWindowSuppressed"

    private var step: SetupStep = .welcome
    private var refresh: Timer?

    // Chrome, reused across steps rather than rebuilt — rebuilding the whole
    // content view every second would drop the device menu while it was open.
    private let dots = StepDots()
    /// Kept so each step can size the window to its own content.
    private var root: NSStackView!
    private let titleLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let controlSlot = NSStackView()
    private let backButton = NSButton(title: "Back", target: nil, action: nil)
    private let nextButton = NSButton(title: "Continue", target: nil, action: nil)
    private let suppressBox = NSButton(checkboxWithTitle: "Don't show this automatically",
                                       target: nil, action: nil)

    // Per-step controls.
    private let grantButton = NSButton(title: "Open Accessibility Settings…",
                                       target: nil, action: nil)
    private let devicePicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let loginToggle = NSButton(checkboxWithTitle: "Start Ratebridge at login",
                                       target: nil, action: nil)

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 430),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Ratebridge Setup"
        super.init(window: window)

        grantButton.target = self;  grantButton.action = #selector(openAccessibility)
        devicePicker.target = self; devicePicker.action = #selector(pickDevice)
        loginToggle.target = self;  loginToggle.action = #selector(toggleLogin)
        backButton.target = self;   backButton.action = #selector(goBack)
        nextButton.target = self;   nextButton.action = #selector(goNext)
        suppressBox.target = self;  suppressBox.action = #selector(toggleSuppress)

        window.delegate = self
        window.contentView = buildContent()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Layout

    private func buildContent() -> NSView {
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)

        bodyLabel.font = .systemFont(ofSize: 12)
        bodyLabel.textColor = .secondaryLabelColor
        bodyLabel.preferredMaxLayoutWidth = 376

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.preferredMaxLayoutWidth = 376

        controlSlot.orientation = .vertical
        controlSlot.alignment = .leading
        controlSlot.spacing = 8

        nextButton.keyEquivalent = "\r"   // Return advances, as in every installer

        let top = NSStackView(views: [titleLabel, bodyLabel, statusLabel, controlSlot])
        top.orientation = .vertical
        top.alignment = .leading
        top.spacing = 12
        top.setCustomSpacing(14, after: bodyLabel)

        let buttons = NSStackView(views: [suppressBox, NSView(), backButton, nextButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 10

        let dotsRow = NSView()
        dots.translatesAutoresizingMaskIntoConstraints = false
        dotsRow.addSubview(dots)
        NSLayoutConstraint.activate([
            dots.centerXAnchor.constraint(equalTo: dotsRow.centerXAnchor),
            dots.topAnchor.constraint(equalTo: dotsRow.topAnchor),
            dots.bottomAnchor.constraint(equalTo: dotsRow.bottomAnchor),
        ])

        let root = NSStackView(views: [top, NSView(), dotsRow, buttons])
        self.root = root
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 18, right: 24)
        root.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: container.topAnchor),
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            buttons.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            dotsRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            dotsRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
        ])
        return container
    }

    private func setControl(_ view: NSView?) {
        for existing in controlSlot.arrangedSubviews {
            controlSlot.removeArrangedSubview(existing)
            existing.removeFromSuperview()
        }
        if let view { controlSlot.addArrangedSubview(view) }
    }

    // MARK: - Showing

    /// True while any actionable step is unsatisfied — the condition for opening
    /// this unprompted. A fully configured install never sees it again.
    static var needsAttention: Bool {
        SetupStep.actionable.contains { !isSatisfied($0) }
    }

    static func isSatisfied(_ step: SetupStep) -> Bool {
        switch step {
        case .accessibility:
            return AXIsProcessTrusted()
        case .device:
            // Only the ambiguous cases count against setup. "system default" is a
            // legitimate resting state for a Mac with one output, not an
            // unfinished step — the tool is designed to work without pinning.
            let reason = Device.targetReason
            return !reason.contains("USB DACs present") && !reason.contains("not connected")
        case .login:
            return SMAppService.mainApp.status == .enabled
        case .welcome, .done:
            return true
        }
    }

    static func showIfNeeded() {
        guard !settings.bool(forKey: suppressKey), needsAttention else { return }
        shared.show()
    }

    func show() {
        // Reopened from the menu, this is the troubleshooting screen, so land on
        // the first thing that is actually wrong rather than making the user page
        // past a welcome they have read. A first run has nothing satisfied yet
        // and so starts at the top anyway.
        step = SetupStep.actionable.first { !Self.isSatisfied($0) }.map { first in
            settings.bool(forKey: Self.suppressKey) ? first : .welcome
        } ?? .welcome
        rebuild()
        // The app is an accessory (LSUIElement), so it cannot take focus by
        // ordinary means — without this the window opens behind whatever the user
        // was doing and reads as "nothing happened".
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        refresh?.invalidate()
        refresh = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.rebuild()
        }
    }

    func windowWillClose(_ notification: Notification) {
        refresh?.invalidate()
        refresh = nil
    }

    // MARK: - Steps

    private func rebuild() {
        let satisfied = Self.isSatisfied(step)

        switch step {
        case .welcome:
            titleLabel.stringValue = "Ratebridge"
            // What the tool is, for someone who was handed a zip and has not
            // read a README. The README's opening assumes you went looking.
            bodyLabel.stringValue = """
                Keeps your DAC's sample rate matched to whatever is playing.

                macOS will not do this on its own: a 96 kHz track sent to a device \
                set to 44.1 kHz is resampled before your DAC ever sees it.

                Three short steps, then it runs on its own from the menu bar.
                """
            statusLabel.stringValue = ""
            setControl(nil)

        case .accessibility:
            titleLabel.stringValue = "Allow Ratebridge to read your player"
            bodyLabel.stringValue = """
                Players hold several tracks open at once, often at different rates. \
                Reading what is on screen is how Ratebridge tells which one you \
                are hearing.

                Without it, those players are skipped rather than guessed at.
                """
            statusLabel.stringValue = satisfied
                ? "✓ Granted."
                : "✗ Not granted yet."
            statusLabel.textColor = satisfied ? .systemGreen : .systemOrange
            if satisfied {
                setControl(nil)
            } else {
                let note = NSTextField(wrappingLabelWithString:
                    "In the pane that opens, switch Ratebridge on. If an old "
                    + "Ratebridge entry is already listed, remove it first — macOS "
                    + "will not rebind a stale entry to a changed signature.")
                note.font = .systemFont(ofSize: 11)
                note.textColor = .tertiaryLabelColor
                note.preferredMaxLayoutWidth = 376
                let stack = NSStackView(views: [grantButton, note])
                stack.orientation = .vertical
                stack.alignment = .leading
                stack.spacing = 8
                setControl(stack)
            }

        case .device:
            titleLabel.stringValue = "Choose the device to follow"
            bodyLabel.stringValue = """
                Ratebridge drives one output device. The system default follows \
                whatever your Mac is playing through.

                Pin your DAC instead if output ever switches away from it.
                """
            let outputs = withAudioDeadline(1) { Device.allOutputs() } ?? []
            rebuildDevicePicker(outputs: outputs)
            statusLabel.stringValue = outputs.isEmpty
                ? "✗ CoreAudio is not responding. If every audio app is frozen too, "
                  + "that is coreaudiod — re-plug the DAC, or run: sudo killall coreaudiod"
                : (satisfied ? "✓ \(bridgeDeviceName) — \(Device.targetReason)"
                             : "✗ \(Device.targetReason)")
            statusLabel.textColor = satisfied && !outputs.isEmpty ? .systemGreen : .systemOrange
            setControl(devicePicker)

        case .login:
            titleLabel.stringValue = "Start with your Mac"
            bodyLabel.stringValue = """
                Ratebridge works only while it is running. Starting at login means \
                the rate is right from the first track you play.

                Optional — you can open it yourself instead.
                """
            loginToggle.state = satisfied ? .on : .off
            statusLabel.stringValue = satisfied
                ? "✓ Ratebridge starts with your Mac."
                : "✗ Ratebridge only runs while you have it open."
            statusLabel.textColor = satisfied ? .systemGreen : .secondaryLabelColor
            setControl(loginToggle)

        case .done:
            titleLabel.stringValue = Self.needsAttention ? "Nearly there" : "Ready"
            bodyLabel.stringValue = Self.needsAttention
                ? "Ratebridge is running. Anything unfinished can be picked up "
                  + "later — choose Setup from the menu bar."
                : "Ratebridge is running and will follow whatever you play. The "
                  + "menu bar shows the current rate; a ⚠ means it is deliberately "
                  + "not switching, and the menu says why."
            statusLabel.stringValue = SetupStep.actionable.map { each in
                (Self.isSatisfied(each) ? "✓ " : "✗ ") + label(for: each)
            }.joined(separator: "\n")
            statusLabel.textColor = .secondaryLabelColor
            setControl(nil)
        }

        dots.update(current: step.rawValue, total: SetupStep.allCases.count)
        fitWindow()

        // Chrome. `done` is the only step that offers to stop showing this,
        // because offering it on step one is offering to skip the thing before
        // it has been explained.
        suppressBox.isHidden = step != .done
        suppressBox.state = settings.bool(forKey: Self.suppressKey) ? .on : .off
        backButton.isHidden = step == .welcome
        nextButton.title = step == .done ? "Done"
            : (step == .welcome ? "Get started" : (satisfied ? "Continue" : "Skip for now"))
    }

    /// Size the window to the step being shown. A single height that fits the
    /// longest step leaves every other one with a hole in the middle, and the
    /// longest step here is nearly twice the shortest. Resized from the top edge
    /// so the title stays put and the buttons come to meet the content, rather
    /// than the whole window jumping up the screen.
    ///
    /// Only when it actually changed: this runs on the same one-second timer as
    /// the live state, and setting the frame every tick makes the window buzz.
    private func fitWindow() {
        guard let window, let root else { return }
        // Lay out first, or fittingSize reports the previous step's height.
        root.layoutSubtreeIfNeeded()
        let height = ceil(root.fittingSize.height)
        // `??` binds looser than `-`, so the obvious one-liner here parses as
        // `height ?? (0 - height)` and compares the wrong number — which made
        // this resize on every tick instead of only on a change.
        let current = window.contentView?.frame.height ?? 0
        guard abs(current - height) > 1 else { return }
        let top = window.frame.maxY
        window.setContentSize(NSSize(width: 440, height: height))
        var frame = window.frame
        frame.origin.y = top - frame.height
        window.setFrame(frame, display: true)
    }

    private func label(for step: SetupStep) -> String {
        switch step {
        case .accessibility: return "Accessibility"
        case .device:        return "Output device — \(bridgeDeviceName)"
        case .login:         return "Open at login"
        default:             return ""
        }
    }



    /// Rebuilt only when the list actually changed. Rebuilding every second would
    /// collapse the menu in the user's face each time the timer fired.
    ///
    /// A pinned device that is not connected is listed explicitly rather than
    /// dropped. Without it the picker fell back to showing "System default" while
    /// the status line said the device was pinned and missing — the two halves of
    /// the same screen contradicting each other.
    private func rebuildDevicePicker(outputs: [Device]) {
        let pinned = settings.string(forKey: "preferredDevice") ?? ""
        var wanted = ["System default"] + outputs.map(\.name)
        let missing = !pinned.isEmpty && !outputs.contains { $0.name == pinned }
        if missing { wanted.append("\(pinned) (not connected)") }

        if devicePicker.itemTitles != wanted {
            devicePicker.removeAllItems()
            devicePicker.addItems(withTitles: wanted)
        }
        let target = pinned.isEmpty ? "System default"
                                    : (missing ? "\(pinned) (not connected)" : pinned)
        if devicePicker.titleOfSelectedItem != target, devicePicker.itemTitles.contains(target) {
            devicePicker.selectItem(withTitle: target)
        }
    }

    // MARK: - Actions

    @objc private func goNext() {
        guard let next = SetupStep(rawValue: step.rawValue + 1) else {
            // Finishing counts as having seen it. Reopening from the menu still
            // works, and lands on whatever is wrong.
            settings.set(true, forKey: Self.suppressKey)
            window?.close()
            return
        }
        step = next
        rebuild()
    }

    @objc private func goBack() {
        guard let previous = SetupStep(rawValue: step.rawValue - 1) else { return }
        step = previous
        rebuild()
    }

    @objc private func openAccessibility() {
        // Prompt first: this registers the app with TCC, so the entry exists to
        // be switched on when the pane opens. Adding it by hand works too, but
        // the pane is far easier to find than the app is.
        if !AXIsProcessTrusted() {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        }
        let url = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        if let link = URL(string: url) { NSWorkspace.shared.open(link) }
    }

    @objc private func pickDevice() {
        guard var title = devicePicker.titleOfSelectedItem else { return }
        if title == "System default" {
            settings.removeObject(forKey: "preferredDevice")
        } else {
            if title.hasSuffix(" (not connected)") { title = String(title.dropLast(16)) }
            settings.set(title, forKey: "preferredDevice")
        }
        rebuild()
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            print("[\(stamp())] login item toggle failed: \(error.localizedDescription)")
        }
        rebuild()
    }

    @objc private func toggleSuppress() {
        settings.set(suppressBox.state == .on, forKey: Self.suppressKey)
    }
}
