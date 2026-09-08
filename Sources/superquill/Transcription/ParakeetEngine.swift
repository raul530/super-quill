import AVFoundation
import FluidAudio
import Foundation

/// Parakeet TDT 0.6B via FluidAudio's Core ML port — v3 (25 European
/// languages, auto-detected, incl. Portuguese and Spanish) by default, or the
/// original English-only v2. Models download once into FluidAudio's managed
/// cache (~500 MB); after that, transcription runs entirely on-device at
/// roughly 20 seconds per hour of audio on Apple Silicon.
actor ParakeetEngine: TranscriptionEngine {
    enum EngineError: Error, CustomStringConvertible {
        case notPrepared
        case unreadableAudio(URL, Error?)
        case audioTooLong(URL, hours: Double)

        var description: String {
            switch self {
            case .notPrepared: return "parakeet engine used before prepare()"
            case .unreadableAudio(let url, let e):
                return "unreadable or empty audio \(url.lastPathComponent)"
                    + (e.map { ": \($0)" } ?? "")
            case .audioTooLong(let url, let hours):
                return String(
                    format: "%@ is %.1f h of audio — past the converter's UInt32 frame limit, not transcribing",
                    url.lastPathComponent, hours
                )
            }
        }
    }

    nonisolated let name: String
    nonisolated let model: String

    private let version: AsrModelVersion
    private var manager: AsrManager?

    init(version: AsrModelVersion = .v3) {
        self.version = version
        switch version {
        case .v2:
            name = "parakeet-v2"
            model = "parakeet-tdt-0.6b-v2-coreml"
        default:
            name = "parakeet"
            model = "parakeet-tdt-0.6b-v3-coreml"
        }
    }

    func prepare() async throws {
        guard manager == nil else { return }
        let models = try await AsrModels.downloadAndLoad(version: version)
        let manager = AsrManager()
        try await manager.loadModels(models)
        self.manager = manager
    }

    func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
        guard let manager else { throw EngineError.notPrepared }

        // A track with no frames (recorder died before its first buffer)
        // makes AVFoundation raise an ObjC exception deep inside the
        // resampler — uncatchable from Swift, so it takes the whole daemon
        // down. Check readability up front instead.
        do {
            let probe = try AVAudioFile(forReading: audio)
            guard probe.length > 0 else { throw EngineError.unreadableAudio(audio, nil) }
            // FluidAudio's converter loop counts remaining frames in
            // AVAudioFrameCount (UInt32) and traps — also uncatchably — on
            // files with more frames than that (~24.8 h at 48 kHz). Refuse
            // them while the error can still be thrown; a file that long is
            // a forgotten recorder, not a meeting.
            guard probe.length <= AVAudioFramePosition(AVAudioFrameCount.max) else {
                throw EngineError.audioTooLong(
                    audio,
                    hours: Double(probe.length) / probe.processingFormat.sampleRate / 3600
                )
            }
        } catch let error as EngineError {
            throw error
        } catch {
            throw EngineError.unreadableAudio(audio, error)
        }

        // The configured language rides along as a decoding hint (v3 only —
        // it pins the output alphabet; the model still detects the language).
        // Read per track, so a menu change applies to the next job.
        let hint = Config.transcriptionLanguage().flatMap(Language.init(rawValue:))
        var state = try TdtDecoderState()
        let result = try await manager.transcribe(audio, decoderState: &state, language: hint)

        let words = buildWordTimings(from: result.tokenTimings ?? [])
        guard !words.isEmpty else {
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty
                ? []
                : [TranscriptSegment(start: 0, end: result.duration, text: text)]
        }
        return Self.segments(from: words)
    }

    func release() async {
        if let manager { await manager.cleanup() }
        manager = nil
    }

    /// Group word timings into readable segments: break on sentence-ending
    /// punctuation (parakeet v2 emits punctuation), a silence gap, or a hard
    /// length cap so a run-on speaker still wraps.
    private static func segments(from words: [WordTiming]) -> [TranscriptSegment] {
        var out: [TranscriptSegment] = []
        var current: [WordTiming] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            out.append(TranscriptSegment(
                start: first.startTime,
                end: last.endTime,
                text: current.map(\.word).joined(separator: " ")
            ))
            current = []
        }

        for word in words {
            if let last = current.last, word.startTime - last.endTime > 1.0 {
                flush()
            }
            current.append(word)
            let endsSentence = word.word.hasSuffix(".")
                || word.word.hasSuffix("?")
                || word.word.hasSuffix("!")
            if endsSentence || current.count >= 60 {
                flush()
            }
        }
        flush()
        return out
    }
}
