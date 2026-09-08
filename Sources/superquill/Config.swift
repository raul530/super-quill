import Foundation

/// Optional user config at ~/.config/superquill/config.json:
///
///     {
///       "recordings_dir": "~/Recordings",
///       "transcription": { "enabled": true, "engine": "parakeet", "language": "pt" },
///       "mic_voice_processing": true,
///       "on_stop": "my-hook",
///       "hotkey": "cmd+f8",
///       "max_hours": 8
///     }
///
/// Resolution order for the recordings root: --out flag > config file >
/// ~/Recordings. `on_stop` is a shell command spawned with the session
/// directory as its argument — after the transcript is written, or right
/// after recording when transcription is disabled.
enum Config {
    static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/superquill/config.json")

    static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Recordings", isDirectory: true)

    /// The configured recordings root, or nil if no config file / no key.
    static func recordingsDir() -> URL? {
        guard let dir = load()?["recordings_dir"] as? String, !dir.isEmpty else { return nil }
        return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Shell command to spawn after each session's transcript is written (or
    /// after recording, if transcription is disabled), or nil.
    static func onStop() -> String? {
        guard let cmd = load()?["on_stop"] as? String, !cmd.isEmpty else { return nil }
        return cmd
    }

    /// Whether stopping a recording pops a dialog asking what to name the
    /// session (the folder becomes "<id> — <name>"). Default on — it's the
    /// superquill signature move; set false for the silent quill behavior.
    static func askName() -> Bool {
        load()?["ask_name"] as? Bool ?? true
    }

    /// Auto-stop cap on a recording, in hours (fractions allowed), or nil for
    /// no cap. A forgotten recorder otherwise runs for days and produces
    /// audio no transcription engine survives.
    static func maxRecordingHours() -> Double? {
        guard let hours = load()?["max_hours"] as? Double, hours > 0 else { return nil }
        return hours
    }

    /// Persist the auto-stop cap chosen in the menu; nil clears it.
    static func setMaxRecordingHours(_ hours: Double?) {
        update("max_hours") { json in
            if let hours {
                json["max_hours"] = hours
            } else {
                json.removeValue(forKey: "max_hours")
            }
        }
    }

    /// Transcription language chosen in the menu ("pt", "es", …), or nil for
    /// automatic detection. With parakeet v3 this is a decoding hint (the
    /// model detects the language on its own; the hint pins the alphabet);
    /// engines that support forced-language decoding honor it outright.
    static func transcriptionLanguage() -> String? {
        guard
            let code = transcription()?["language"] as? String,
            !code.isEmpty, code != "auto"
        else { return nil }
        return code
    }

    /// Persist the menu's language choice under transcription.language,
    /// keeping the rest of the transcription block; nil restores auto.
    static func setTranscriptionLanguage(_ code: String?) {
        update("language") { json in
            var block = json["transcription"] as? [String: Any] ?? [:]
            if let code {
                block["language"] = code
            } else {
                block.removeValue(forKey: "language")
            }
            if block.isEmpty {
                json.removeValue(forKey: "transcription")
            } else {
                json["transcription"] = block
            }
        }
    }

    /// Rewrite the config file with `mutate` applied, keeping every other
    /// key. The rewrite is a JSON round-trip, so hand formatting is lost but
    /// content isn't; a malformed config is left untouched — clobbering the
    /// user's file to store one setting is worse than not persisting.
    private static func update(_ what: String, _ mutate: (inout [String: Any]) -> Void) {
        var json: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: path.path) {
            guard let existing = load() else {
                FileHandle.standardError.write(Data(
                    "warning: not saving \(what) — fix \(path.path) first\n".utf8
                ))
                return
            }
            json = existing
        }
        mutate(&json)
        do {
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONSerialization.data(
                withJSONObject: json,
                options: [.prettyPrinted, .sortedKeys]
            ).write(to: path, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data(
                "warning: couldn't save \(what): \(error)\n".utf8
            ))
        }
    }

    /// Global shortcut that toggles recording, e.g. "cmd+f8" (the default),
    /// "cmd+shift+r". Set to "" to disable the hotkey entirely.
    static func hotkey() -> String? {
        guard let value = load()?["hotkey"] as? String else { return "cmd+f8" }
        return value.isEmpty ? nil : value
    }

    /// Whether finished recordings are transcribed automatically. Default on.
    static func transcriptionEnabled() -> Bool {
        transcription()?["enabled"] as? Bool ?? true
    }

    /// Configured engine name. "parakeet" (multilingual v3, the default) and
    /// "parakeet-v2" (the original English-only model) ship today; the
    /// coordinator warns and falls back for anything else.
    static func transcriptionEngine() -> String {
        transcription()?["engine"] as? String ?? "parakeet"
    }

    private static func transcription() -> [String: Any]? {
        load()?["transcription"] as? [String: Any]
    }

    /// Apple voice processing (acoustic echo cancellation) on the mic, so
    /// speaker playback doesn't bleed into the mic track and get transcribed
    /// as "me". Default off — the live voice unit ducks all other playback,
    /// and on headphones there's no echo to cancel anyway. Set true when
    /// recording meetings through the speakers.
    static func micVoiceProcessing() -> Bool {
        load()?["mic_voice_processing"] as? Bool ?? false
    }

    /// Parse the config file. A malformed config is reported on stderr rather
    /// than silently ignored — recordings landing in an unexpected place is
    /// worse than a warning.
    private static func load() -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        guard
            let data = try? Data(contentsOf: path),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            FileHandle.standardError.write(Data(
                "warning: \(path.path) is not valid JSON — ignoring config\n".utf8
            ))
            return nil
        }
        return json
    }

    /// Resolve the recordings root from an optional CLI override.
    static func resolveRoot(cliOverride: String?) -> URL {
        if let cliOverride {
            return URL(
                fileURLWithPath: (cliOverride as NSString).expandingTildeInPath,
                isDirectory: true
            )
        }
        return recordingsDir() ?? defaultRoot
    }
}
