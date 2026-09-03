import AppKit
import ArgumentParser
import Foundation

@main
struct Quill: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "superquill",
        abstract: "Local meeting recorder + transcriber. Records mic and system audio as two tracks, then transcribes on-device.",
        subcommands: [Run.self, Doctor.self, Install.self],
        defaultSubcommand: Run.self
    )
}

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run the menu-bar daemon (default)."
    )

    @Option(name: .long, help: "Recordings root directory (overrides the config file).")
    var out: String?

    func run() throws {
        // ArgumentParser invokes run() on the main thread; promote that fact
        // to the type system so AppKit calls are cleanly isolated.
        try MainActor.assumeIsolated { try runMain() }
    }

    @MainActor
    private func runMain() throws {
        let root = Config.resolveRoot(cliOverride: out)

        // Non-blocking: permissions prompt on first recording, so warnings at
        // startup are informational, not fatal.
        let checks = DoctorReport.run(recordingsRoot: root)
        if !DoctorReport.allOK(checks) {
            FileHandle.standardError.write(Data("startup checks failed:\n".utf8))
            DoctorReport.print(checks)
            throw ExitCode(1)
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let controller = AppController(root: root)

        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler {
            FileHandle.standardError.write(Data("\nshutting down\n".utf8))
            MainActor.assumeIsolated { controller.shutdown() }
        }
        sigint.resume()
        signal(SIGINT, SIG_IGN)

        FileHandle.standardError.write(Data(
            "superquill up · recordings → \(root.path) · ^C to quit\n".utf8
        ))
        app.run()
    }
}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check microphone, system audio, and recordings folder."
    )

    func run() throws {
        let checks = DoctorReport.run(recordingsRoot: Config.resolveRoot(cliOverride: nil))
        DoctorReport.print(checks)
        if !DoctorReport.allOK(checks) {
            throw ExitCode(1)
        }
    }
}

/// Owns the menu bar, the current recording session, and the elapsed-time
/// ticker. All state transitions happen on the main actor.
@MainActor
final class AppController {
    private let root: URL
    private let menuBar = MenuBarController()
    private let transcription = TranscriptionCoordinator()
    private var session: RecordingSession?
    private var ticker: Timer?
    private var hotkey: GlobalHotkey?
    /// Auto-stop deadline, captured from config when the session starts so a
    /// mid-recording config edit has a well-defined (no) effect.
    private var maxDuration: TimeInterval?

    init(root: URL) {
        self.root = root
        menuBar.onToggle = { [weak self] in self?.toggle() }
        menuBar.onOpenFolder = { [weak self] in self?.openFolder() }
        menuBar.onQuit = { [weak self] in self?.shutdown() }
        menuBar.update(recording: false, elapsed: nil)

        if let spec = Config.hotkey() {
            hotkey = GlobalHotkey(spec: spec) { [weak self] in self?.toggle() }
            if hotkey == nil {
                FileHandle.standardError.write(Data(
                    "hotkey \"\(spec)\" could not be registered — fix \"hotkey\" in the config or pick another combo\n".utf8
                ))
            }
        }

        Task { [transcription, root] in
            await transcription.setStatusHandler { status in
                Task { @MainActor [weak self] in
                    self?.showTranscription(status)
                }
            }
            await transcription.resumePending(root: root)
        }
    }

    /// Stop any live session cleanly (finalizing files) and exit.
    func shutdown() {
        stopSession()
        NSApp.terminate(nil)
    }

    private func toggle() {
        if session == nil {
            startSession()
        } else {
            stopSession(askName: true)
        }
    }

    private func startSession() {
        do {
            let newSession = try RecordingSession(root: root)
            try newSession.start()
            session = newSession
            FileHandle.standardError.write(Data("● recording → \(newSession.dir.path)\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("recording start failed: \(error)\n".utf8))
            notifyUser(title: "superquill — recording failed", body: "\(error)")
            return
        }

        maxDuration = Config.maxRecordingHours().map { $0 * 3600 }
        menuBar.update(recording: true, elapsed: "0:00")
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// `askName` pops the naming dialog — true only for a deliberate stop
    /// (menu click, hotkey). Auto-stop and quit never block on a modal.
    private func stopSession(askName: Bool = false) {
        guard let session else { return }
        session.stop()
        let elapsed = Self.format(Date().timeIntervalSince(session.startedAt))
        FileHandle.standardError.write(Data(
            "○ stopped · \(elapsed) · \(session.dir.path)\n".utf8
        ))
        self.session = nil
        ticker?.invalidate()
        ticker = nil
        menuBar.update(recording: false, elapsed: nil)

        // Name before enqueueing: the coordinator holds the folder URL for
        // the whole transcription, so the rename must happen first.
        var dir = session.dir
        if askName, Config.askName() {
            dir = Self.promptForName(of: dir, elapsed: elapsed)
        }
        Task { [transcription] in await transcription.enqueue(dir) }
    }

    /// Ask what this recording was and rename its folder to "<id> — <name>"
    /// — the same shape the on_stop pipeline gives auto-titled sessions, so
    /// a name typed here wins (downstream tooling keeps parsing the id off
    /// the prefix) and the raw-timestamp auto-title step skips it.
    /// Returns the folder to use afterwards: renamed, or unchanged on skip.
    private static func promptForName(of dir: URL, elapsed: String) -> URL {
        let alert = NSAlert()
        alert.messageText = "Name this recording"
        alert.informativeText = "\(dir.lastPathComponent) · \(elapsed)"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Skip")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "Weekly sync with design"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return dir }

        let name = sanitized(field.stringValue)
        guard !name.isEmpty else { return dir }
        let target = dir.deletingLastPathComponent()
            .appendingPathComponent("\(dir.lastPathComponent) — \(name)", isDirectory: true)
        do {
            try FileManager.default.moveItem(at: dir, to: target)
            FileHandle.standardError.write(Data(
                "named → \(target.lastPathComponent)\n".utf8
            ))
            return target
        } catch {
            FileHandle.standardError.write(Data(
                "couldn't rename session: \(error)\n".utf8
            ))
            return dir
        }
    }

    /// Folder-safe name: no path or control characters, collapsed
    /// whitespace, bounded length, and no trailing dot/space (invisible
    /// landmines in folder names).
    private static func sanitized(_ raw: String) -> String {
        let cleaned = raw
            .replacingOccurrences(of: "/", with: " ")
            .replacingOccurrences(of: ":", with: " ")
            .components(separatedBy: .controlCharacters).joined()
            .split(separator: " ").joined(separator: " ")
        return String(cleaned.prefix(60))
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    }

    private func showTranscription(_ status: TranscriptionCoordinator.Status) {
        switch status {
        case .idle:
            menuBar.updateTranscription(nil)
        case .transcribing(let name, let queued):
            menuBar.updateTranscription(
                queued > 0 ? "transcribing \(name) · \(queued) queued" : "transcribing \(name)"
            )
        case .failed(let name):
            menuBar.updateTranscription("transcription failed · \(name)")
        }
    }

    private func tick() {
        guard let session else { return }
        let elapsed = Date().timeIntervalSince(session.startedAt)
        if let maxDuration, elapsed >= maxDuration {
            FileHandle.standardError.write(Data(
                "max_hours reached — auto-stopping \(session.dir.lastPathComponent)\n".utf8
            ))
            notifyUser(
                title: "superquill — recording auto-stopped",
                body: "hit max_hours after \(Self.format(elapsed)) — \(session.dir.lastPathComponent)"
            )
            stopSession()
            return
        }
        menuBar.update(recording: true, elapsed: Self.format(elapsed))
    }

    private func openFolder() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(root)
    }

    private static func format(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
