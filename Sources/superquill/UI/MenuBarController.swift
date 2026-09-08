import AppKit

/// Status bar item in the top-right of the menu bar. Shows recording state at
/// a glance and provides the only persistent control surface for the daemon
/// (since we run as `.accessory` — no dock icon, no main window).
@MainActor
final class MenuBarController {
    private let statusItem: NSStatusItem
    private let stateLabel: NSMenuItem
    private let transcriptionLabel: NSMenuItem
    private let toggleItem: NSMenuItem
    private let autoStopItem: NSMenuItem
    private let autoStopMenu = NSMenu()
    private var customAutoStopItem: NSMenuItem?
    private let languageItem: NSMenuItem
    private let languageMenu = NSMenu()
    private var customLanguageItem: NSMenuItem?

    /// Auto-stop presets offered in the menu, in hours; nil = no limit. A
    /// hand-edited config value outside this list gets its own checked row.
    private static let autoStopChoices: [Double?] = [nil, 1, 2, 4, 8]

    /// Transcription languages offered in the menu; nil = auto-detect. Any
    /// other parakeet-v3 code set by hand in the config gets its own row.
    private static let languageChoices: [(code: String?, label: String)] = [
        (nil, "Auto"),
        ("en", "English"),
        ("pt", "Português"),
        ("es", "Español"),
    ]

    var onToggle: (() -> Void)?
    var onOpenFolder: (() -> Void)?
    var onQuit: (() -> Void)?
    var onAutoStopChange: ((Double?) -> Void)?
    var onLanguageChange: ((String?) -> Void)?

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        menu.autoenablesItems = false

        stateLabel = NSMenuItem(title: "idle", action: nil, keyEquivalent: "")
        stateLabel.isEnabled = false
        menu.addItem(stateLabel)

        transcriptionLabel = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        transcriptionLabel.isEnabled = false
        transcriptionLabel.isHidden = true
        menu.addItem(transcriptionLabel)

        menu.addItem(.separator())

        toggleItem = NSMenuItem(
            title: "Start recording",
            action: #selector(toggleClicked),
            keyEquivalent: "r"
        )
        menu.addItem(toggleItem)

        languageItem = NSMenuItem(title: "Language: auto", action: nil, keyEquivalent: "")
        languageMenu.autoenablesItems = false
        for choice in Self.languageChoices {
            let item = NSMenuItem(
                title: choice.label,
                action: #selector(languageClicked(_:)),
                keyEquivalent: ""
            )
            item.representedObject = choice.code
            languageMenu.addItem(item)
        }
        languageItem.submenu = languageMenu
        menu.addItem(languageItem)

        autoStopItem = NSMenuItem(title: "Auto-stop: off", action: nil, keyEquivalent: "")
        autoStopMenu.autoenablesItems = false
        for hours in Self.autoStopChoices {
            let item = NSMenuItem(
                title: Self.autoStopTitle(hours),
                action: #selector(autoStopClicked(_:)),
                keyEquivalent: ""
            )
            item.tag = Self.tag(for: hours)
            autoStopMenu.addItem(item)
        }
        autoStopItem.submenu = autoStopMenu
        menu.addItem(autoStopItem)

        let openFolder = NSMenuItem(
            title: "Open recordings folder",
            action: #selector(openFolderClicked),
            keyEquivalent: "o"
        )
        menu.addItem(openFolder)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit superquill",
            action: #selector(quitClicked),
            keyEquivalent: "q"
        )
        menu.addItem(quit)

        for item in [toggleItem, openFolder, quit] + autoStopMenu.items + languageMenu.items {
            item.target = self
        }

        statusItem.menu = menu

        if let button = statusItem.button {
            let image = Self.featherImage()
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeft
        }
    }

    /// Reflect recording state in the icon tint and menu item titles. The
    /// menu bar shows only the feather (red while recording); the elapsed
    /// counter lives in the menu's state label. Call once a second while
    /// recording.
    func update(recording: Bool, elapsed: String?) {
        stateLabel.title = recording ? "● recording · \(elapsed ?? "0:00")" : "idle"
        toggleItem.title = recording ? "Stop recording" : "Start recording"
        statusItem.button?.contentTintColor = recording ? .systemRed : nil
    }

    /// Show transcription progress/failure as a second status line in the
    /// menu; nil hides it. Independent of recording state — a new recording
    /// can run while the last one transcribes.
    func updateTranscription(_ text: String?) {
        transcriptionLabel.title = text ?? ""
        transcriptionLabel.isHidden = text == nil
    }

    /// Reflect the active auto-stop limit: checkmark the matching preset and
    /// show the value on the submenu's parent item so it reads without
    /// opening. A non-preset value (hand-edited config) gets a temporary row
    /// of its own so the checkmark never lies.
    func updateAutoStop(_ hours: Double?) {
        autoStopItem.title = hours.map { "Auto-stop: \(Self.hoursLabel($0))" } ?? "Auto-stop: off"

        if let custom = customAutoStopItem {
            autoStopMenu.removeItem(custom)
            customAutoStopItem = nil
        }
        let tag = Self.tag(for: hours)
        var matched = false
        for item in autoStopMenu.items {
            item.state = item.tag == tag ? .on : .off
            matched = matched || item.tag == tag
        }
        if !matched, let hours {
            let custom = NSMenuItem(
                title: Self.hoursLabel(hours),
                action: #selector(autoStopClicked(_:)),
                keyEquivalent: ""
            )
            custom.tag = tag
            custom.state = .on
            custom.target = self
            autoStopMenu.addItem(custom)
            customAutoStopItem = custom
        }
    }

    /// Reflect the transcription language: checkmark the matching row and
    /// show the choice on the parent item. A hand-edited non-preset code
    /// (e.g. "fr") gets a temporary checked row so the menu never lies.
    func updateLanguage(_ code: String?) {
        let label = Self.languageChoices.first { $0.code == code }?.label
            ?? code?.uppercased()
        languageItem.title = "Language: \(code == nil ? "auto" : (label ?? "auto"))"

        if let custom = customLanguageItem {
            languageMenu.removeItem(custom)
            customLanguageItem = nil
        }
        var matched = false
        for item in languageMenu.items {
            let on = (item.representedObject as? String) == code
            item.state = on ? .on : .off
            matched = matched || on
        }
        if !matched, let code {
            let custom = NSMenuItem(
                title: code.uppercased(),
                action: #selector(languageClicked(_:)),
                keyEquivalent: ""
            )
            custom.representedObject = code
            custom.state = .on
            custom.target = self
            languageMenu.addItem(custom)
            customLanguageItem = custom
        }
    }

    private static func tag(for hours: Double?) -> Int {
        Int(((hours ?? 0) * 60).rounded())
    }

    private static func autoStopTitle(_ hours: Double?) -> String {
        hours.map(hoursLabel) ?? "Off"
    }

    private static func hoursLabel(_ hours: Double) -> String {
        hours == 1 ? "1 hour" : "\(hours.formatted()) hours"
    }

    // Inlined Lucide feather SVG plus a sparkle badge — the badge is what
    // tells superquill apart from plain quill at a glance in the menu bar.
    // Keeping it in source means the executable has no separate resource
    // bundle to install alongside it — true single-binary.
    private static let featherSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" \
    viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" \
    stroke-linecap="round" stroke-linejoin="round">\
    <path d="M12.67 19a2 2 0 0 0 1.416-.588l6.154-6.172a6 6 0 0 0-8.49-8.49L5.586 9.914A2 2 0 0 0 5 11.328V18a1 1 0 0 0 1 1z"/>\
    <path d="M16 8 2 22"/>\
    <path d="M17.5 15H9"/>\
    <path d="M4.5 1 L5.3 3.2 7.5 4 5.3 4.8 4.5 7 3.7 4.8 1.5 4 3.7 3.2 Z" \
    fill="currentColor" stroke="none"/>\
    </svg>
    """

    private static func featherImage() -> NSImage? {
        guard let data = featherSVG.data(using: .utf8),
              let image = NSImage(data: data)
        else { return nil }
        // Menu-bar status icons are nominally 18pt tall; size the SVG to match.
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    @objc private func toggleClicked() { onToggle?() }
    @objc private func openFolderClicked() { onOpenFolder?() }
    @objc private func quitClicked() { onQuit?() }
    @objc private func autoStopClicked(_ sender: NSMenuItem) {
        onAutoStopChange?(sender.tag == 0 ? nil : Double(sender.tag) / 60)
    }
    @objc private func languageClicked(_ sender: NSMenuItem) {
        onLanguageChange?(sender.representedObject as? String)
    }
}
