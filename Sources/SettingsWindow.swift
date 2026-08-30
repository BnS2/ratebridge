// Settings, for people who do not want to type a bundle identifier.
//
// The CLI stays the source of truth and this is a second view onto the same
// UserDefaults store — `ratebridge rule`, `config` and `priority` read and write
// exactly what this does, so neither can drift from the other. What the CLI
// cannot do is show you a list of the apps on your Mac: it asks for
// `com.wangchujiang.musicer`, and nobody who has not read the README knows that
// string or how to find it. That is the whole reason this window exists, and it
// is why the app list is built from running applications with their real names
// and icons rather than from a text field.
//
// Deliberately not everything the CLI can do. Routing declarations and the
// ignore list are diagnosis-shaped — you reach for them after `probe` has told
// you something — and putting them here would imply a casual user should be
// thinking about them.

import AppKit
// For AudioObjectID alone: the rows name the device an app renders on, and
// that is the id CoreAudio hands back.
import CoreAudio
import ServiceManagement

/// What the user can decide about one app.
///
/// Deliberately short. The engine can read an app four ways — its window, its
/// open file, an Apple Event, a declared constant — but those are mechanisms,
/// and nobody who has not read the source can choose between them. Offering all
/// four asked the user to make the tool's decision for it, and the tool is
/// better placed to make it. `ratebridge rule` still exposes every one of them,
/// which is the same split the rest of the app uses.
///
/// What is left is what a listener knows: leave it alone, this app is always one
/// rate, or keep it away from my DAC entirely. Three items, with the rates one
/// level in — a device that does 384 kHz would otherwise put nine of them in
/// front of someone who wanted "leave it alone".
private enum AppSetting {
    case automatic
    case fixed(Float64)
    case ignore
    /// An override the CLI can express and this window cannot — a `ui`, `file`
    /// or `script` rule. Shown as itself rather than rounded to the nearest
    /// option, because rounding it would rewrite a rule the user set
    /// deliberately the moment they touched anything else on the row.
    case advanced

    var title: String {
        switch self {
        case .automatic:      return "Automatic"
        case .fixed(let r):   return "Always \(formatRate(r))"
        case .ignore:         return "Excluded"
        case .advanced:       return "Command line rule"
        }
    }

    /// Read from the user's *override*, never from the effective policy.
    ///
    /// A built-in rule is not a decision the user made, so VLC must read
    /// "Automatic" rather than "Read the file it has open" — otherwise the
    /// window reports settings nobody chose.
    static func from(override raw: String?) -> AppSetting {
        guard let raw, let policy = Policy.parse(raw) else { return .automatic }
        switch policy {
        case .off:            return .ignore
        case .fixed(let r):   return .fixed(r)
        default:              return .advanced
        }
    }
}

/// The rates worth offering for a per-app pin.
///
/// Taken from the target device, because a rate it cannot do is a rate the write
/// would fail on — a menu that offers 192 kHz on a device that stops at 96 is
/// offering a setting that does nothing.
///
/// Per-*app* capability is not derivable, and it is worth being clear about why
/// rather than pretending: an app renders into whatever the device already
/// holds, so nothing reports what it "supports". Pinning a browser to 192 kHz
/// is accepted by everything involved and simply means the browser upsamples
/// 48 into 192. That it is a bad idea is a judgement, not a constraint, which is
/// exactly why browsers ship with a 48 kHz constant instead of a pin.
///
/// Anything below 44.1 is dropped: a device that offers 8 or 32 kHz is offering
/// it for voice capture, and it is not a rate anyone pins music to.
func pinnableRates() -> [Float64] {
    let rates = (withAudioDeadline(1) { Device.target()?.availableRates } ?? nil) ?? []
    let usable = rates.filter { $0 >= 44100 }.sorted()
    return usable.isEmpty ? [44100, 48000, 96000] : usable
}

/// A button that looks like a pop-up and shows a menu we build.
///
/// NSPopUpButton draws the control correctly but will not do the job: its menu
/// is documented as not supporting submenus, and the rates need one. Subclassing
/// it and overriding `mouseDown` does not help either — the cell does the mouse
/// tracking, so the click never reaches the override and the button opens its
/// own one-item menu instead. Observed, not assumed.
///
/// So this is a plain NSButton, whose menu is ours and demonstrably works, wearing
/// the layout people expect from a pop-up: label against the left edge, chevron
/// pinned to the right, rather than a centred title with a chevron typed after it.
final class MenuButton: NSButton {
    private let chevron = NSImageView()

    /// - Parameter plain: for a menu that belongs to a line of prose rather than
    ///   to the control column. The destination line is a *statement you can
    ///   correct*, not a setting you operate, and a second full-weight pop-up
    ///   beside the rate one said the opposite — two controls of equal loudness
    ///   asking to be compared. Inline bezel, subtitle type size, and the
    ///   chevron is the only thing announcing it opens.
    init(title: String, plain: Bool = false) {
        super.init(frame: .zero)
        self.title = title
        bezelStyle = plain ? .inline : .rounded
        alignment = .left
        if plain {
            controlSize = .small
            font = .systemFont(ofSize: 11)
            // Measured, not padded with spaces. The chevron is a subview pinned
            // to the right edge, and AppKit gives a button no content inset — so
            // a self-sizing button draws the title straight through it. The
            // fixed-width rate pop-up never showed this; this one hugs its
            // title, so it has to be told how much room the chevron needs.
            let width = (title as NSString)
                .size(withAttributes: [.font: font ?? .systemFont(ofSize: 11)]).width
            widthAnchor.constraint(equalToConstant: ceil(width) + 32).isActive = true
        }
        // Room at the right for the chevron, which is a subview rather than the
        // button's own image: `imageTrailing` puts it immediately after the
        // title, which lands it in the middle of the control.
        let config = NSImage.SymbolConfiguration(pointSize: plain ? 8 : 10,
                                                 weight: .medium)
        chevron.image = NSImage(systemSymbolName: "chevron.up.chevron.down",
                                accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        chevron.contentTintColor = .secondaryLabelColor
        chevron.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chevron)
        NSLayoutConstraint.activate([
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor,
                                              constant: plain ? -6 : -9),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// AppKit's coordinate origin is bottom-left, so a document view shorter than its
/// scroll view sits at the *bottom* of it — the app list started halfway down an
/// empty pane. A flipped container puts the origin at the top, where a list
/// belongs.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// One row's facts, in the terms the row speaks: what Ratebridge does with this
/// app, and whether that is your doing.
///
/// It used to carry where the app renders, how that was known, and whether you
/// had declared otherwise — three facts about audio paths, which is a subject
/// this program has no authority over and cannot move. A row that talks about
/// audio paths ends up looking like the router that moves them.
private struct AppEntry {
    /// What the rule is written under: the bundle id when there is one, the
    /// executable name when there is not. The same key `ratebridge rule` takes,
    /// and the same one `AudioProcess.label` reports.
    let key: String
    let name: String
    /// Counted as playing on the device Ratebridge manages — measured where the
    /// target is the system output, assumed where it cannot be.
    let reaches: Bool
    /// Marked "Excluded": its sound does not come out of the target, or you
    /// simply do not want its rate. One mark, because those have one effect.
    let excluded: Bool
}

final class SettingsWindowController: NSWindowController, NSMenuDelegate, NSTextFieldDelegate {
    static let shared = SettingsWindowController()

    private let tabs = NSTabView()
    private let appList = NSStackView()
    private var refresh: Timer?

    // General tab controls.
    private let restingPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let idleDelayField = NSTextField(string: "")
    private let playerDelayField = NSTextField(string: "")
    private let conflictPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    // A switch rather than a checkbox, and untitled. Every other row here is
    // "label, then the control it belongs to", and the checkbox's own title
    // said the row's label a second time in different words — "Start with your
    // Mac" followed by "Start Ratebridge at login". The switch is also what
    // System Settings uses for a plain on/off, which is what this is.
    private let loginToggle = NSSwitch()
    private let muteToggle = NSSwitch()
    private let deviceValue = NSTextField(labelWithString: "—")
    private let muteHint = NSTextField(wrappingLabelWithString: "")
    private let muteTitle = NSTextField(labelWithString: "Silence the system output")
    private let restingHint = NSTextField(wrappingLabelWithString: "")
    private let deviceHint = NSTextField(wrappingLabelWithString: "")

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 660),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Ratebridge Settings"
        // Taller, never wider. The list grows with the number of apps making
        // noise, so height is worth dragging; every card, row and control on
        // both tabs is laid out against one fixed width, and a wider window
        // would only add empty space to the right of them.
        window.minSize = NSSize(width: 600, height: 420)
        window.maxSize = NSSize(width: 600, height: 1400)
        super.init(window: window)
        window.contentView = buildContent()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        rebuildApps(force: true)
        rebuildGeneral()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        // Apps come and go while this is open; a list that only reflects the
        // moment it was opened would tell you an app you can hear is not there.
        refresh?.invalidate()
        refresh = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.rebuildApps()
            self?.refreshGeneral()
        }
    }

    // MARK: - Layout

    private func buildContent() -> NSView {
        appList.orientation = .vertical
        appList.alignment = .leading
        appList.spacing = 14
        // Right inset is the wide one: the scroller floats over the content, and
        // at 16 all round the popups sat under it.
        appList.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 22, right: 26)

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        appList.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(appList)
        NSLayoutConstraint.activate([
            appList.topAnchor.constraint(equalTo: document.topAnchor),
            appList.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            appList.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            appList.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])

        let appsTab = NSTabViewItem(identifier: "apps")
        appsTab.label = "Apps"
        appsTab.view = scrolled(document)

        let generalTab = NSTabViewItem(identifier: "general")
        generalTab.label = "General"
        generalTab.view = scrolled(buildGeneral())

        tabs.addTabViewItem(appsTab)
        tabs.addTabViewItem(generalTab)
        tabs.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(tabs)
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            tabs.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            tabs.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            tabs.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])
        return container
    }

    /// A pane that can be taller than the window.
    ///
    /// The Apps tab always had this; General did not, and it had quietly grown
    /// past 440pt — so "Accessibility and output device", the row that opens the
    /// setup walkthrough, was below the sill with no scroller to reach it. A
    /// settings window with an unreachable setting is the one bug a settings
    /// window cannot have, and it does not announce itself: nothing is drawn
    /// wrong, there is simply less of it than there should be.
    ///
    /// Flipped document view for the same reason as the app list: AppKit's
    /// origin is bottom-left, so an unflipped document shorter than its scroll
    /// view sits at the bottom of it.
    private func scrolled(_ content: NSView) -> NSScrollView {
        let document: NSView
        if content is FlippedView {
            document = content
        } else {
            let flipped = FlippedView()
            content.translatesAutoresizingMaskIntoConstraints = false
            flipped.addSubview(content)
            NSLayoutConstraint.activate([
                content.topAnchor.constraint(equalTo: flipped.topAnchor),
                content.leadingAnchor.constraint(equalTo: flipped.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: flipped.trailingAnchor),
                content.bottomAnchor.constraint(equalTo: flipped.bottomAnchor),
            ])
            document = flipped
        }
        document.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = document
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ])
        return scroll
    }

    // MARK: - Grouped layout

    /// The width both tabs lay out against, and the width of a card.
    private let cardWidth: CGFloat = 514
    /// A card's own padding, so a row inside one knows how much room it has.
    private let cardPadding: CGFloat = 14
    private var rowWidth: CGFloat { cardWidth - cardPadding * 2 }

    /// A System Settings-style group: one rounded card, hairline rules between
    /// its rows.
    ///
    /// Both tabs were a column of loose rows with air between them, which left
    /// every control floating on its own — a switch here, a pop-up there, a
    /// checkbox below, none of them sharing an edge with anything. That is what
    /// read as unfinished: not any single control, but that nothing lined up.
    /// A card gives them a common left edge, a common right edge, and a rule
    /// between neighbours, which is all "designed" means here.
    private func card(_ rows: [NSView]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let rule = NSBox()
                rule.boxType = .separator
                rule.translatesAutoresizingMaskIntoConstraints = false
                rule.widthAnchor.constraint(equalToConstant: cardWidth).isActive = true
                stack.addArrangedSubview(rule)
            }
            stack.addArrangedSubview(padded(row))
        }

        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = 8
        box.borderWidth = 1
        box.borderColor = .separatorColor
        box.fillColor = .controlBackgroundColor
        // Otherwise NSBox insets its content by its own margins and the rules
        // stop short of the card's edges, which looks like a mistake because it
        // is one.
        box.contentViewMargins = .zero
        box.contentView = stack
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: cardWidth).isActive = true
        return box
    }

    private func padded(_ view: NSView) -> NSView {
        let container = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor,
                                          constant: cardPadding),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor,
                                           constant: -cardPadding),
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
        ])
        return container
    }

    /// One setting: name on the left, its control against the right edge, and
    /// the reason underneath.
    ///
    /// The control column is what was missing. Left-aligned controls of
    /// different widths — a switch, a 90pt pop-up, two text fields, a 300pt
    /// pop-up — make a ragged edge down the middle of the page, and the eye
    /// reads ragged as unfinished before it reads a single word.
    /// - Parameter under: draws the row as a qualifier of the one above it —
    ///   indented, one size down. "Even if something else is playing there" is
    ///   not a sixth setting, it is the second half of the fifth, and a row of
    ///   equal weight said otherwise.
    private func settingRow(_ label: String, _ control: NSView, _ note: String,
                            under: Bool = false) -> NSView {
        settingRow(NSTextField(labelWithString: label), control,
                   hint: NSTextField(wrappingLabelWithString: note), under: under)
    }

    private func settingRow(_ label: String, _ control: NSView, hint: NSTextField,
                            under: Bool = false) -> NSView {
        settingRow(NSTextField(labelWithString: label), control, hint: hint, under: under)
    }

    /// - Parameter title: a label rather than a string, for the rows whose name
    ///   states a fact about this Mac. A title is as capable of being wrong as a
    ///   hint is, and "Silence the built-in speakers" was wrong on any Mac whose
    ///   system output is a monitor, a headset or an interface.
    private func settingRow(_ title: NSTextField, _ control: NSView, hint: NSTextField,
                            under: Bool = false) -> NSView {
        title.font = .systemFont(ofSize: under ? 12 : 13)
        if under { title.textColor = .secondaryLabelColor }
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let head = NSStackView(views: [title, NSView(), control])
        head.orientation = .horizontal
        head.alignment = .centerY
        head.spacing = 10

        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.preferredMaxLayoutWidth = rowWidth

        let stack = NSStackView(views: [head, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: rowWidth).isActive = true
        head.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        guard under else { return stack }

        // Indented from the left only. The control column is the page's spine
        // and every switch on it lines up whatever the row's rank.
        let indented = NSView()
        stack.removeConstraint(stack.constraints.first { $0.firstAttribute == .width }!)
        indented.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: indented.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: indented.trailingAnchor),
            stack.topAnchor.constraint(equalTo: indented.topAnchor),
            stack.bottomAnchor.constraint(equalTo: indented.bottomAnchor),
        ])
        indented.translatesAutoresizingMaskIntoConstraints = false
        indented.widthAnchor.constraint(equalToConstant: rowWidth).isActive = true
        hint.preferredMaxLayoutWidth = rowWidth - 18
        return indented
    }

    /// A section label above a card, in the register the app list already uses.
    private func section(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text.uppercased())
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        return label
    }

    /// Rates worth resting at, taken from the device instead of from a guess.
    ///
    /// This was three hardcoded titles — 44.1, 48, 96 — and they were wrong in
    /// both directions: a device that stops at 48 kHz was still offered 96, and
    /// a device that does 192 could not be parked there from this window at all.
    /// The quieter failure was worse. The picker selects by title, so an
    /// `idle-rate` set from the CLI to anything outside those three matched no
    /// item and left whatever was selected before showing — the window
    /// reporting a setting the Mac did not have.
    ///
    /// The stored value is always in the list, even when the device does not
    /// claim it. A picker that cannot show the current setting is worse than one
    /// offering a rate that will not take.
    private func restingRates() -> [Float64] {
        var rates = pinnableRates()
        if !rates.contains(where: { abs($0 - restingRate) < 1 }) { rates.append(restingRate) }
        return rates.sorted()
    }

    private func buildGeneral() -> NSView {
        restingPicker.target = self
        restingPicker.action = #selector(changeResting)

        conflictPicker.addItems(withTitles: ["Follow the more important app",
                                             "Leave the device alone"])
        conflictPicker.target = self
        conflictPicker.action = #selector(changeConflict)

        for field in [idleDelayField, playerDelayField] {
            field.target = self
            field.action = #selector(changeDelays)
            // Commit on the way out as well as on Return. Without this, typing
            // 45 and clicking anywhere else threw the 45 away and the field
            // silently reverted on the next refresh — a settings field that
            // discards what you typed unless you happen to press a key nothing
            // told you about.
            field.delegate = self
            field.widthAnchor.constraint(equalToConstant: 54).isActive = true
        }

        func unit(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            return label
        }
        let delays = NSStackView(views: [
            idleDelayField, unit("s normally,"),
            playerDelayField, unit("s with a player open"),
        ])
        delays.orientation = .horizontal
        delays.alignment = .centerY
        delays.spacing = 6

        loginToggle.target = self
        loginToggle.action = #selector(toggleLogin)
        // The visible label is the row's, so VoiceOver needs to be told what
        // this untitled control is.
        loginToggle.setAccessibilityLabel("Start Ratebridge at login")

        muteToggle.target = self
        muteToggle.action = #selector(toggleSwitchMute)
        muteToggle.setAccessibilityLabel("Mute the system output while switching")

        let setupButton = NSButton(title: "Open Setup Guide…", target: self,
                                   action: #selector(openSetupGuide))
        setupButton.bezelStyle = .rounded

        let resetButton = NSButton(title: "Restore Defaults…", target: self,
                                   action: #selector(restoreDefaults))
        resetButton.bezelStyle = .rounded

        // The device row is a fact, not a control: the one piece of context that
        // makes half this page make sense — "Silence the switch" is meaningless
        // until you know these two are different devices — and the window never
        // said it anywhere except inside the Apps tab's banner.
        deviceValue.font = .systemFont(ofSize: 13, weight: .medium)
        deviceValue.textColor = .secondaryLabelColor

        // Four groups, in the order the questions occur to someone: is it
        // running, where does it park the device, what does it do while I am
        // listening, and what is left for me to set up by hand. Ungrouped, the
        // page was six unrelated settings in a column and the reader had to sort
        // them into these four themselves.
        let groups: [(String, [NSView])] = [
            ("Startup", [
                settingRow("Start with your Mac", loginToggle,
                           "Ratebridge only sets rates while it is running."),
            ]),
            ("When nothing is playing", [
                settingRow("Resting rate", restingPicker, hint: restingHint),
                settingRow("Wait before resting", delays,
                           "A paused player gets the longer wait, so an unfinished session keeps its rate."),
            ]),
            ("While something is playing", [
                settingRow("When two apps play at once", conflictPicker,
                           "No single rate suits both; the one you do not follow is resampled."),
                // Phrased by what it prevents, not by what it does to your
                // speakers. "Mute the system output" describes the mechanism and
                // sounds like a thing that could go wrong; the leak is what the
                // reader has heard.
                // One toggle, not two. "Even if something else is playing there"
                // was the second half of this and it should never have been a
                // question: with it off the guard stood down exactly when a leak
                // was loudest, and nobody sits down and chooses the leak. What
                // is a real preference is the outer one — may this app touch
                // your built-in speakers at all — so that is what the row asks.
                settingRow(muteTitle, muteToggle, hint: muteHint),
            ]),
            // The walkthrough, reachable but not competing with this window for
            // the same job. It used to be a menu item called "Setup…" one line
            // from "Settings…", which asked the reader to tell two near-identical
            // words apart before they knew what either did.
            ("Start over", [
                settingRow("Restore defaults", resetButton,
                           "Puts every setting on this page back, and clears every per-app "
                           + "rate and exclusion. Your output device and login item stay."),
            ]),
            ("Devices", [
                settingRow("Output device", deviceValue, hint: deviceHint),
                settingRow("Accessibility and output device", setupButton,
                           "The three things Ratebridge cannot set for itself."),
            ]),
        ]

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        for (title, rows) in groups {
            let heading = section(title)
            stack.addArrangedSubview(heading)
            stack.setCustomSpacing(7, after: heading)
            let group = card(rows)
            stack.addArrangedSubview(group)
            stack.setCustomSpacing(16, after: group)
        }
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 22, right: 26)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    // MARK: - Apps tab

    /// Apps this list has been asked to show, for as long as the window is open.
    ///
    /// Without it, setting a row back to Automatic deletes its override and the
    /// row vanishes on the next refresh — the app apparently deleting itself
    /// because you chose the default.
    private var pinnedRows: Set<String> = []

    /// True while one of the row menus is open.
    ///
    /// The refresh timer rebuilds every row, which destroys the button a live
    /// menu belongs to — so a menu open across a tick lost the click that was
    /// about to land in it. The same guard exists in the Setup window's device
    /// picker; it simply was not carried over here.
    private var menuIsOpen = false

    /// What the list was last built from. Rebuilding identical rows four times a
    /// minute is churn nobody asked for, and every rebuild is a chance to
    /// interrupt something.
    private var lastSignature: String?

    func controlTextDidEndEditing(_ obj: Notification) { changeDelays() }

    func menuWillOpen(_ menu: NSMenu) { menuIsOpen = true }
    func menuDidClose(_ menu: NSMenu) { menuIsOpen = false }

    /// The user's list, not a catalogue.
    ///
    /// It used to print every entry in the built-in rule table, which meant a Mac
    /// with none of them installed opened Settings to a page about VLC, IINA, Vox
    /// and QuickTime — the same failure `probe` had before it stopped naming two
    /// apps that were not there. Those rules still exist and still work; they
    /// simply are not decisions anyone needs to see.
    private func rebuildApps(force: Bool = false) {
        let overrides = (settings.dictionary(forKey: "rules") as? [String: String]) ?? [:]
        let mismatch = outputMismatch()

        // Two sections, because they answer two different questions. "What is
        // making noise right now, and how is Ratebridge reading it" is the one
        // you open this window holding; "what have I changed" is the one you come
        // back to later. Merged into one list, the app you can hear is buried
        // among apps you configured months ago.
        // `reaches` is asked here, where the process object still exists, rather
        // than re-derived per row from a bundle id — the answer is "CoreAudio
        // sees it on our device, or the user declared it", and only the process
        // can answer the first half.
        let target = (withAudioDeadline(1) { Device.target() }) ?? nil

        // Uncached, unlike everywhere else. The cached list drops apps ruled off
        // — and "ruled off" is now the exclusion the user makes from this very
        // window, so the cached list would delete the row the moment you used
        // it. `probe` already learned this lesson: a list that silently omits
        // what you can hear is worse than no list.
        // Every process holding an output stream, not only the ones that came
        // from an installed app bundle.
        //
        // The old guard wanted a bundle id and a resolvable app, which quietly
        // dropped `afplay`, media helpers and anything a game spawns. That was
        // survivable while nothing counted until it was declared. Under the
        // inclusive default those processes are followed like any other — they
        // can take the device to their own rate — so a list that hides them
        // shows you a device being driven by something you cannot see, and
        // offers no way to exclude it.
        var playing: [AppEntry] = []
        var seen = Set<String>()
        for process in (withAudioDeadline(1) { uncachedActiveOutputProcesses() } ?? []) {
            guard seen.insert(process.label).inserted else { continue }
            playing.append(AppEntry(key: process.label, name: process.displayName,
                                    reaches: target.map { process.reaches($0) } ?? true,
                                    excluded: isRuledOff(process)))
        }
        let winner = bridgeWinner

        var yours: [AppEntry] = []
        for bundleID in Set(overrides.keys).union(pinnedRows).union(routedProcesses).sorted()
        where seen.insert(bundleID).inserted {
            let excluded = overrides[bundleID].flatMap { Policy.parse($0) }.map {
                if case .off = $0 { return true } else { return false }
            } ?? false
            yours.append(AppEntry(key: bundleID,
                                  name: appDisplayName(bundleID: bundleID, fallback: bundleID),
                                  reaches: !excluded, excluded: excluded))
        }

        // Everything the list is drawn from. If none of it moved there is
        // nothing to redraw, and redrawing anyway is what pulled the rug from
        // under an open menu.
        let signature = ([playing.map(\.key).joined(separator: ","),
                          yours.map(\.key).joined(separator: ","),
                          overrides.map { "\($0)=\($1)" }.sorted().joined(separator: ","),
                          routedProcesses.sorted().joined(separator: ","),
                          mismatch.map { "\($0.system)→\($0.target)" } ?? "",
                          playing.map { "\($0.key):\($0.reaches):\($0.excluded)" }
                            .joined(separator: ","),
                          winner ?? ""])
            .joined(separator: "|")
        if !force {
            guard !menuIsOpen else { return }
            guard signature != lastSignature else { return }
        }
        lastSignature = signature

        for existing in appList.arrangedSubviews {
            appList.removeArrangedSubview(existing)
            existing.removeFromSuperview()
        }

        func setting(_ bundleID: String) -> AppSetting {
            AppSetting.from(override: overrides[bundleID])
        }

        // Above both sections, because it changes what every row below it means.
        if let mismatch {
            let banner = outputBanner(target: mismatch.target, system: mismatch.system,
                                      declared: (playing + yours).contains(where: \.excluded))
            appList.addArrangedSubview(banner)
            appList.setCustomSpacing(24, after: banner)
        }

        func group(_ title: String, _ rows: [NSView]) {
            let heading = section(title)
            appList.addArrangedSubview(heading)
            appList.setCustomSpacing(7, after: heading)
            let box = card(rows)
            appList.addArrangedSubview(box)
            appList.setCustomSpacing(24, after: box)
        }

        if !playing.isEmpty {
            group("Playing now", playing.map { entry in
                appRow(entry, setting: setting(entry.key),
                       isSource: entry.key == winner, live: true, target: target?.name)
            })
        }

        if !yours.isEmpty {
            group("Your apps", yours.map { entry in
                appRow(entry, setting: setting(entry.key), target: target?.name)
            })
        }

        if playing.isEmpty && yours.isEmpty {
            let empty = NSTextField(wrappingLabelWithString:
                "Nothing is playing. Ratebridge follows your players without being "
                + "told to — add an app here only to change how it reads that one.")
            empty.font = .systemFont(ofSize: 12)
            empty.textColor = .secondaryLabelColor
            empty.preferredMaxLayoutWidth = 514
            appList.addArrangedSubview(empty)
        }

        // "Add Application", not "Add App…". The ellipsis promises a dialog that
        // asks you something; this drops a menu of running apps under the
        // button, which is the answer, not a request for one.
        let add = NSButton(title: "Add Application", target: self,
                           action: #selector(addApp(_:)))
        add.bezelStyle = .rounded
        // Against the right edge, under the control column. Every other thing
        // you can press on this page lines up there, and a lone button on the
        // left made the page end on a ragged edge that nothing else shared.
        let addRow = NSStackView(views: [NSView(), add])
        addRow.orientation = .horizontal
        addRow.alignment = .centerY
        addRow.translatesAutoresizingMaskIntoConstraints = false
        addRow.widthAnchor.constraint(equalToConstant: cardWidth).isActive = true
        appList.addArrangedSubview(addRow)
        // Set the button apart from the rows: it acts on the list rather than
        // being another item in it.
        if let previous = appList.arrangedSubviews.dropLast().last {
            appList.setCustomSpacing(24, after: previous)
        }
    }

    /// The target device and the system output, when they are not the same one.
    ///
    /// This is the one condition under which a row's rate can be set correctly
    /// and still do nothing: macOS sends the app's audio somewhere else, so it
    /// never counts as reaching the device Ratebridge manages, and the bridge
    /// rests. `ratebridge status` has always printed it; the window said nothing,
    /// which left the resting rate looking like a bug in the rate you chose.
    ///
    /// Deliberately not a per-row dependency. A row's declaration does not gate
    /// its dropdown — an app CoreAudio can see is a source whether or not it is
    /// ticked — and greying rows would state the opposite. The fact is about the
    /// device, so it belongs above the list, once.
    private func outputMismatch() -> (target: String, system: String)? {
        let pair = withAudioDeadline(1) { () -> (String, String)? in
            guard let target = Device.target(), let system = Device.defaultOutput(),
                  system.id != target.id else { return nil }
            return (target.name, system.name)
        }
        return pair ?? nil
    }

    /// Says what is true, what follows from it, and nothing else.
    ///
    /// Tone is the whole job here. Pointing a DAC at a per-app router while the
    /// system output stays on the speakers is a correct setup that plenty of
    /// people run deliberately, so a banner that reads as a fault report is
    /// wrong about the machine as well as rude — it tells someone whose rig is
    /// working that they have something to fix. Three things caused that and all
    /// three are gone: the orange warning triangle (now a plain ⓘ), a title
    /// phrased as a deviation ("is *not* the system output"), and the absence of
    /// any sentence admitting the arrangement is normal.
    ///
    /// No button either. Both cures are real choices — tick the apps a router
    /// carries, or point Ratebridge at the system output — and neither is the
    /// one this window should make on the user's behalf.
    ///
    /// - Parameter declared: whether anything is excluded yet. Somebody who has
    ///   excluded an app has understood the arrangement, so the note drops its
    ///   tutorial and keeps only the rule. A note that repeats its lesson after
    ///   you have acted on it is nagging.
    private func outputBanner(target: String, system: String, declared: Bool) -> NSView {
        let symbol = NSImageView()
        symbol.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        symbol.contentTintColor = .secondaryLabelColor
        symbol.setContentHuggingPriority(.required, for: .horizontal)

        // Naming the resting rate is what closes the loop for the reader who has
        // watched the device drop to it and wondered which setting was broken.
        let explained = "macOS sends audio to \"\(system)\" and cannot say which apps "
            + "another program carries to \"\(target)\". So Ratebridge counts everything "
            + "that plays — set an app to \"Excluded\" when its sound comes out somewhere "
            + "else, the way a browser or a chat app usually does. This is the normal "
            + "arrangement when another app feeds the device."
        let stated = "macOS sends audio to \"\(system)\", so Ratebridge counts everything "
            + "that plays as reaching \"\(target)\" unless you exclude it."

        let body = NSTextField(wrappingLabelWithString: declared ? stated : explained)
        body.font = .systemFont(ofSize: 11)
        body.textColor = .secondaryLabelColor
        body.preferredMaxLayoutWidth = 432

        let text = NSStackView(views: [body])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3

        // A heading only while there is something to explain. Phrased as the
        // question it answers — how apps get there — rather than as what is
        // missing, which is the same fact with a complaint attached.
        if !declared {
            let title = NSTextField(labelWithString: "How apps reach \"\(target)\"")
            title.font = .systemFont(ofSize: 12, weight: .medium)
            text.insertArrangedSubview(title, at: 0)
        }

        // The ⓘ centred against the whole note.
        //
        // It used to be pinned to the middle of the *first line*, on the theory
        // that a reader's eye starts there. On a two-line note that reads as
        // simply not centred, which is what it is: the symbol has a whole box of
        // text beside it and sits against the top third of it. Whatever the
        // argument, the eye settles it.

        let content = NSView()
        symbol.translatesAutoresizingMaskIntoConstraints = false
        text.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(symbol)
        content.addSubview(text)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            symbol.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            symbol.centerYAnchor.constraint(equalTo: text.centerYAnchor),
            text.leadingAnchor.constraint(equalTo: symbol.trailingAnchor, constant: 9),
            text.topAnchor.constraint(equalTo: content.topAnchor),
            text.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            text.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        // NSBox rather than a coloured rectangle: it is the control that already
        // draws a grouping in the system's own border and fill, so the note stays
        // right in both appearances without a palette of its own — and a neutral
        // container is the difference between a note and an alert.
        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = 6
        box.borderWidth = 1
        box.borderColor = .separatorColor
        box.fillColor = .underPageBackgroundColor
        box.contentView = content
        box.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: 514),
            content.topAnchor.constraint(equalTo: box.topAnchor, constant: 11),
            content.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12),
            content.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -11),
        ])
        return box
    }

    @objc private func showRowMenu(_ sender: NSButton) {
        guard let bundleID = sender.identifier?.rawValue else { return }
        let overrides = (settings.dictionary(forKey: "rules") as? [String: String]) ?? [:]
        let menu = rowMenu(for: bundleID, current: AppSetting.from(override: overrides[bundleID]))
        dropBelow(menu, sender)
    }

    /// Open a menu directly under its button.
    ///
    /// Positioned in screen coordinates rather than the button's own. The
    /// view-relative form is ambiguous here: these buttons live inside a flipped
    /// scroll container, and passing the bottom edge put the menu *over* the
    /// control you had just clicked rather than under it. Screen coordinates have
    /// one meaning — y grows upward — so the button's bottom-left corner is the
    /// answer whatever the view hierarchy is doing.
    private func dropBelow(_ menu: NSMenu, _ sender: NSView) {
        guard let window = sender.window else {
            menu.popUp(positioning: nil, at: .zero, in: sender)
            return
        }
        let inWindow = sender.convert(sender.bounds, to: nil)
        let corner = NSPoint(x: inWindow.minX, y: inWindow.minY - 4)
        menu.popUp(positioning: nil, at: window.convertPoint(toScreen: corner), in: nil)
    }

    private func rowMenu(for bundleID: String, current: AppSetting) -> NSMenu {
        let menu = NSMenu()
        // So the refresh timer does not rebuild the row this menu hangs from
        // while it is open.
        menu.delegate = self

        let automatic = NSMenuItem(title: "Automatic", action: #selector(setAutomatic(_:)),
                                   keyEquivalent: "")
        automatic.target = self
        automatic.representedObject = bundleID
        if case .automatic = current { automatic.state = .on }
        menu.addItem(automatic)

        let always = NSMenuItem(title: "Always this rate", action: nil, keyEquivalent: "")
        let rates = NSMenu()
        for rate in pinnableRates() {
            let item = NSMenuItem(title: formatRate(rate), action: #selector(setRate(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = [bundleID, "\(Int(rate))"]
            if case .fixed(let chosen) = current, Int(chosen) == Int(rate) { item.state = .on }
            rates.addItem(item)
        }
        always.submenu = rates
        if case .fixed = current { always.state = .on }
        menu.addItem(always)

        // The exclusion, and the only per-app control on the page besides the
        // rate. Named for the state it puts the app in rather than for the verb
        // "ignore", because the two reasons people reach for it — its sound does
        // not come out of my device, and I do not want its rate — have one
        // effect, and one effect deserves one control.
        let ignore = NSMenuItem(title: "Excluded", action: #selector(setIgnore(_:)),
                                keyEquivalent: "")
        ignore.target = self
        ignore.representedObject = bundleID
        if case .ignore = current { ignore.state = .on }
        menu.addItem(ignore)

        // Names the device, like every other line that refers to it. "Your
        // output device" is a phrase the reader has to resolve before the
        // sentence means anything, and they are reading it precisely because
        // they are unsure which device is which.
        let managed = (withAudioDeadline(1) { Device.target()?.name }) ?? nil
        let named = managed.map { "\"\($0)\"" } ?? "your output device"
        let why = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        why.attributedTitle = NSAttributedString(
            string: "Its sound does not come out of \(named),\n"
                + "or you simply do not want Ratebridge following it.",
            attributes: [.font: NSFont.systemFont(ofSize: 11),
                         .foregroundColor: NSColor.secondaryLabelColor])
        why.isEnabled = false
        menu.addItem(why)

        return menu
    }

    /// Running apps that are not already listed    /// Running apps that are not already listed, by name and icon. Running rather
    /// than installed on purpose: an open-panel over /Applications offers a
    /// hundred things that never make a sound, and the app you want is by
    /// definition open when you come looking for it.
    @objc private func addApp(_ sender: NSButton) {
        let overrides = (settings.dictionary(forKey: "rules") as? [String: String]) ?? [:]
        let already = Set(overrides.keys).union(pinnedRows)
        let menu = NSMenu()
        let candidates = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> (String, String, NSImage?)? in
                guard let bundleID = app.bundleIdentifier, !already.contains(bundleID),
                      let name = app.localizedName else { return nil }
                return (bundleID, name, app.icon)
            }
            .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }

        for (bundleID, name, icon) in candidates {
            let item = NSMenuItem(title: name, action: #selector(pickApp(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = bundleID
            icon?.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
        }
        if candidates.isEmpty {
            menu.addItem(NSMenuItem(title: "Every running app is already listed",
                                    action: nil, keyEquivalent: ""))
        }
        // Same guard as the row menus: this one is opened over a list that a
        // timer rebuilds, and the button it hangs from goes with it.
        menu.delegate = self
        dropBelow(menu, sender)
    }

    @objc private func pickApp(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        pinnedRows.insert(bundleID)
        rebuildApps(force: true)
    }

    /// A small tinted capsule, in the register of the section headers above it.
    ///
    /// NSBox rather than a layer-backed view: a `cgColor` set once does not
    /// follow the system between light and dark, and these rows are only rebuilt
    /// when something about them changes — which a theme switch is not.
    ///
    /// One badge survives, and deliberately only one. Destination used to be a
    /// badge too, which put two pills of different colours on a row and asked
    /// the reader to work out that they answered different questions. It is now
    /// a line of prose with a menu in it, and a row that has one pill has one
    /// thing worth noticing.
    private func badge(_ text: String, _ tint: NSColor) -> NSView {
        let label = NSTextField(labelWithString: text.uppercased())
        label.font = .systemFont(ofSize: 9, weight: .semibold)
        label.textColor = tint
        label.translatesAutoresizingMaskIntoConstraints = false

        let pill = NSBox()
        pill.boxType = .custom
        pill.borderWidth = 0
        pill.cornerRadius = 4
        pill.fillColor = tint.withAlphaComponent(0.14)
        pill.contentView = label
        pill.setContentHuggingPriority(.required, for: .horizontal)
        pill.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: pill.topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -2),
        ])
        return pill
    }

    /// One app, in two lines: what it is and how its rate is read, then what
    /// Ratebridge does with it.
    ///
    /// The second line went through three drafts before this one, and the two it
    /// discarded both failed the same way. "Elsewhere" named a state without
    /// naming a device. "Plays on ⟨device ⌄⟩" named the device and turned the
    /// row into a destination picker — which is a router's control, and this
    /// program cannot move a single sample. Anything shaped like a device menu
    /// will be read as one.
    ///
    /// So the line does not talk about audio paths at all. It says what this
    /// program does, which is the only subject it has authority over: this app
    /// is counted as playing on your device, or it is not. The one control that
    /// changes it lives in the rate menu, where "Excluded" is a policy among
    /// policies rather than a claim about somebody else's software.
    private func appRow(_ entry: AppEntry, setting: AppSetting,
                        isSource: Bool = false, live: Bool = false,
                        target: String?) -> NSView {
        // The running app's icon, else the installed bundle's. Only the first
        // was ever asked, so every row in "Your apps" — by definition the apps
        // that are *not* playing — wore the same blank placeholder, and a list
        // of identical grey squares is a list you have to read to use.
        let icon = NSImageView()
        icon.image = NSRunningApplication
            .runningApplications(withBundleIdentifier: entry.key)
            .first?.icon
            ?? appBundleURL(entry.key).map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSWorkspace.shared.icon(forFileType: "app")
        icon.widthAnchor.constraint(equalToConstant: 28).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 28).isActive = true

        let name = NSTextField(labelWithString: entry.name)
        name.font = .systemFont(ofSize: 13)
        // The badge keeps its width; a long app name gives way instead. It is
        // three words and cannot survive being clipped, and the name is already
        // legible from its icon.
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // The one badge: who is driving the device right now. It comes from the
        // running bridge, not from anything this window re-derives, so the badge
        // and the device always agree.
        var badges: [NSView] = []
        if isSource { badges.append(badge("setting the rate", .controlAccentColor)) }

        // Off the target, and not because you said so: CoreAudio reports this app
        // on a device that is neither ours nor the system output, so it is
        // measurably somewhere else. Nothing on this row can change that, which
        // is why its rate menu is dead — a rate is a thing you set on the device
        // Ratebridge manages, and this app is not on it. When it next plays
        // there the menu comes back by itself, with no state to undo.
        let offTarget = live && !entry.reaches && !entry.excluded

        let picker = MenuButton(title: setting.title)
        picker.target = self
        picker.action = #selector(showRowMenu(_:))
        picker.identifier = NSUserInterfaceItemIdentifier(entry.key)
        picker.isEnabled = !offTarget
        // Wide enough for the titles people actually see — "Always 384 kHz" and
        // "Command line rule" — rather than for the one nobody does.
        picker.widthAnchor.constraint(equalToConstant: 170).isActive = true

        let head = NSStackView(views: [name] + badges + [NSView(), picker])
        head.orientation = .horizontal
        head.alignment = .centerY
        head.spacing = 12
        if !badges.isEmpty { head.setCustomSpacing(7, after: name) }

        // An app that is out is drawn as out. It is also the only thing the row
        // needs to say: the menu already reads "Excluded" when that was your
        // doing, so a line underneath repeating it in other words was the third
        // draft's habit of explaining itself twice.
        if !entry.reaches {
            icon.alphaValue = 0.45
            name.textColor = .secondaryLabelColor
        }

        let state = NSTextField(labelWithString: "Not on \"\(target ?? "your output device")\"")
        state.font = .systemFont(ofSize: 11)
        state.textColor = .tertiaryLabelColor

        let column = NSStackView(views: offTarget ? [head, state] : [head])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 3
        column.translatesAutoresizingMaskIntoConstraints = false
        column.widthAnchor.constraint(equalToConstant: rowWidth - 40).isActive = true
        head.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true

        // The icon spans both lines, which is what makes them one row rather
        // than two entries — the same shape a Finder row or a System Settings
        // list uses for a title with a subtitle under it.
        let row = NSStackView(views: [icon, column])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        return row
    }

    // MARK: - General tab

    /// The CLI writes the same defaults this tab reads, so a window left open
    /// across a `ratebridge config` was showing an answer that was no longer
    /// true — a switch sitting off beside a feature the daemon was running.
    /// Rebuilt on the same tick as the app list, except while a text field is
    /// being edited: rewriting a number under the cursor is worse than being two
    /// seconds behind.
    private func refreshGeneral() {
        guard !(window?.firstResponder is NSText) else { return }
        rebuildGeneral()
    }

    private func rebuildGeneral() {
        // Rebuilt rather than built once: plug in a different DAC and the set of
        // rates it can rest at changes under an open window. Guarded on the menu
        // being open for the same reason the app list is — replacing the items
        // under a menu the user is reading throws the click away.
        let titles = restingRates().map(formatRate)
        if restingPicker.itemTitles != titles, !menuIsOpen {
            restingPicker.removeAllItems()
            restingPicker.addItems(withTitles: titles)
            restingPicker.menu?.delegate = self
        }
        restingPicker.selectItem(withTitle: formatRate(restingRate))
        // The recommendation only if the device can take it. Naming 48 kHz to
        // someone whose DAC does not offer it is advice they cannot follow, and
        // this row's whole bug was a list that assumed rates rather than asking.
        restingHint.stringValue = "Where the device goes when nothing is playing"
            + (restingRates().contains(where: { abs($0 - 48000) < 1 })
               ? " — 48 kHz suits a quiet Mac." : ".")
        idleDelayField.stringValue = "\(Int(idleRestDelay))"
        playerDelayField.stringValue = "\(Int(idleRestDelayPlayerOpen))"
        conflictPicker.selectItem(at: conflictPolicy == .hold ? 1 : 0)
        loginToggle.state = SMAppService.mainApp.status == .enabled ? .on : .off
        muteToggle.state = switchMuteGrace > 0 ? .on : .off
        let devices = withAudioDeadline(1) { () -> (String, String?) in
            let target = Device.target()?.name
            let system = Device.defaultOutput()?.name
            return (target ?? "none — nothing pinned or detected",
                    target == system ? nil : system)
        }
        if let (target, system) = devices {
            deviceValue.stringValue = target
            // The hint carries the reconciliation, and only when there is one to
            // carry: two different devices is the fact that makes the rest of
            // this page legible, and one device is a fact with nothing to say.
            deviceHint.stringValue = system.map {
                "Ratebridge manages this one. macOS sends its own audio to \"\($0)\", "
                + "which is why a rate change can be heard there."
            } ?? "Ratebridge manages this one, and it is where macOS sends audio too."
            // The same fact decides whether the mute has any work to do at all,
            // so the row says so rather than sitting there implying it does.
            // Named, not assumed. The device this silences is whatever macOS is
            // currently sending audio to, which is a monitor as often as it is
            // the built-in speakers.
            muteTitle.stringValue = system.map { "Silence \"\($0)\"" }
                ?? "Silence the system output"
            muteHint.stringValue = system.map {
                "A rate change can let a redirected app out of \"\($0)\" for an instant. "
                + "This keeps it quiet until your device is streaming again — including "
                + "when something else is playing there, which takes the same short gap."
            } ?? "Nothing to silence on this Mac: your device is where macOS sends audio, "
               + "so a rate change has nowhere to leak."
        }
    }

    // MARK: - Actions

    private func writeRule(_ bundleID: String, _ raw: String?) {
        var overrides = (settings.dictionary(forKey: "rules") as? [String: String]) ?? [:]
        if let raw { overrides[bundleID] = raw } else { overrides.removeValue(forKey: bundleID) }
        settings.set(overrides, forKey: "rules")
        pinnedRows.insert(bundleID)   // keep the row visible after it goes back to Automatic
        rebuildApps(force: true)
    }

    @objc private func setAutomatic(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        writeRule(bundleID, nil)
    }

    @objc private func setIgnore(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        writeRule(bundleID, "off")
    }

    @objc private func setRate(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2 else { return }
        writeRule(pair[0], pair[1])
    }

    /// Read back through the same formatter that wrote the titles, so the
    /// round-trip is exact and no index into a parallel array can drift out of
    /// step with the menu — which is precisely how the old list managed to write
    /// 96 kHz when a device offered 88.2.
    @objc private func changeResting() {
        guard let title = restingPicker.titleOfSelectedItem,
              let rate = restingRates().first(where: { formatRate($0) == title })
        else { return }
        settings.set(rate, forKey: "idleRate")
    }

    @objc private func changeDelays() {
        if let normal = Double(idleDelayField.stringValue), normal > 0 {
            settings.set(normal, forKey: "idleRestDelay")
        }
        if let open = Double(playerDelayField.stringValue), open > 0 {
            settings.set(open, forKey: "idleRestDelayPlayerOpen")
        }
        rebuildGeneral()
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
        rebuildGeneral()
    }

    /// Off writes 0; on writes the default grace rather than whatever custom
    /// number the CLI may have set, because a switch has no way to show one.
    @objc private func toggleSwitchMute() {
        settings.set(muteToggle.state == .on ? 0.35 : 0, forKey: "muteDuringSwitch")
        rebuildGeneral()
    }

    /// The way back, for someone who has tried everything and can no longer tell
    /// which of their changes is the one hurting them.
    ///
    /// Confirmed first, and the alert names both halves — what goes and what
    /// stays — because "restore defaults" is a phrase people read as narrower
    /// than it is, and the per-app rules are the part they will not expect. It
    /// calls the same `resetSettings` the CLI does, so the two can never mean
    /// different things by "defaults".
    @objc private func restoreDefaults() {
        let alert = NSAlert()
        alert.messageText = "Restore Ratebridge's defaults?"
        alert.informativeText = """
            This clears every setting in this window — resting rate, waits,             conflict policy, the switch mute — and every per-app rate, exclusion             and routing declaration.

            Your output device stays pinned, and Ratebridge keeps starting with             your Mac. Neither can be undone from here, so neither is touched.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Restore Defaults")
        alert.addButton(withTitle: "Cancel")
        // Escape and Return both land on Cancel's side of the fence: the
        // destructive button is first, so it takes Return, and that is the one
        // key a hurried reader presses. Making Cancel the key equivalent for
        // Escape only is not enough — this makes Return do nothing at all.
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\u{1b}"
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        resetSettings(includingApps: true)
        pinnedRows.removeAll()
        rebuildGeneral()
        rebuildApps(force: true)
    }

    @objc private func openSetupGuide() {
        SetupWindowController.shared.show()
    }

    /// Writes `conflict`, which is the key the engine reads.
    ///
    /// It wrote `conflictPolicy` — a key nothing has ever read. So this control
    /// did nothing at all: pick "Leave the device alone", and the bridge carried
    /// on following the more important app while the picker snapped back to the
    /// old value on the next two-second refresh. Found by enumerating every
    /// stored key while building Restore Defaults, not by anyone noticing, which
    /// is the trouble with a control that fails silently.
    @objc private func changeConflict() {
        settings.set(conflictPicker.indexOfSelectedItem == 1 ? "hold" : "priority",
                     forKey: "conflict")
    }
}
