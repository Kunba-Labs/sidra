#if os(macOS)
import AppKit
import AVFoundation
import Accelerate
import Speech
import Observation
import SidraDesign
import SidraTerminal
import WhisperKit

/// Dictation into the focused terminal on the Mac. ⌥⌘V or the title bar's mic starts it; Return or
/// the same key inserts the words at the cursor (bracketed paste, so a newline does not run them),
/// Esc drops them. Speech becomes text on this Mac: Apple's dictation model by default, or Whisper
/// large-v3 once its model is downloaded (Settings → Voice; 626 MB, optional).
@MainActor @Observable
final class VoiceInput {
    static let shared = VoiceInput()

    enum Engine: String, CaseIterable { case apple, whisper }
    enum Phase: Equatable {
        case idle
        case preparing(String)       // a language pack or the Whisper model loading
        case recording
        case transcribing
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// Words heard so far: Apple's volatile results, or Whisper's live pass.
    private(set) var partial = ""
    private(set) var elapsed: TimeInterval = 0
    /// Recent input levels, 0…1, newest last: the overlay's bars.
    private(set) var levels: [Float] = []
    /// Whisper model download progress, 0…1; nil when not downloading.
    private(set) var downloadProgress: Double?
    var downloadError: String?

    /// Observable, so Settings updates at once; persisted for the next launch.
    var engine: Engine = Engine(rawValue: UserDefaults.standard.string(forKey: "sidra.voiceEngine") ?? "") ?? .apple {
        didSet { UserDefaults.standard.set(engine.rawValue, forKey: "sidra.voiceEngine") }
    }
    /// Whisper only once its model is on disk; Apple otherwise.
    private var activeEngine: Engine { engine == .whisper && whisperOnDisk ? .whisper : .apple }

    private let audio = AVAudioEngine()
    /// 16 kHz mono for Whisper, written from the microphone's thread, so a buffer still on its way when
    /// recording stops is not dropped.
    private let audioStore = SampleStore()
    private var samples: [Float] { audioStore.all }
    private var started = Date()
    private var clock: Task<Void, Never>?
    private var liveTask: Task<Void, Never>?
    private var keyMonitor: Any?

    // Apple
    private var analyzer: SpeechAnalyzer?
    private var feed: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var finalText = ""
    private var appleFormat: AVAudioFormat?

    // Whisper
    private var whisper: WhisperKit?
    static let whisperVariant = "large-v3-v20240930_626MB"
    static let whisperSize = "626 MB"

    var isActive: Bool { phase != .idle }
    /// Preparing or writing out: the mic has nothing to do until that ends.
    var isBusy: Bool { if case .preparing = phase { true } else { phase == .transcribing } }

    // MARK: Start / stop

    /// ⌥⌘V and the mic button: start, or insert what was said.
    func toggle() {
        // From another window: show the one that is dictating rather than finish its recording.
        if isActive, let w = window, NSApp.keyWindow !== w { w.makeKeyAndOrderFront(nil); return }
        switch phase {
        case .recording: finish(insert: true)
        case .idle, .failed: start()
        default: break
        }
    }

    /// The window dictating; its terminal is looked up again when the words are inserted.
    private(set) var window: NSWindow?
    /// The engine this recording uses, fixed at start: a settings change mid-recording does not switch it.
    private var sessionEngine: Engine = .apple
    private var prep: Task<Void, Never>?
    private var session = UUID()

    /// The terminal focused in the dictating window now, or the one that last had focus there (a click on
    /// the mic can take first responder). Hidden terminals (another tab) do not count. Nil: the clipboard.
    var currentTarget: GhosttyMacView? {
        guard let w = window else { return nil }
        let t = (w.firstResponder as? GhosttyMacView) ?? GhosttyMacView.lastFocused.flatMap { $0.window === w ? $0 : nil }
        return t.flatMap { $0.isHiddenOrHasHiddenAncestor ? nil : $0 }
    }
    var hasTarget: Bool { currentTarget != nil }

    func start() {
        window = NSApp.keyWindow
        sessionEngine = activeEngine
        let id = UUID(); session = id
        phase = .preparing("Listening soon…")
        installKeys()   // Esc cancels while preparing too
        prep = Task {
            let allowed = await AVCaptureDevice.requestAccess(for: .audio)
            guard !Task.isCancelled, session == id else { return }   // cancelled during the prompt
            guard allowed else {
                return fail("Sidra may not use the microphone. Allow it in System Settings → Privacy & Security → Microphone.")
            }
            do {
                if sessionEngine == .whisper { try await loadWhisper() } else { try await prepareApple(session: id) }
                // Cancelled, or a newer start took over, while this was loading: do not open the microphone.
                guard !Task.isCancelled, session == id, case .preparing = phase else { return }
                try startAudio()
            } catch {
                if session == id, !Task.isCancelled { fail("Could not start listening: \(error.localizedDescription)") }
            }
        }
    }

    /// Return inserts, Esc drops.
    func finish(insert: Bool) {
        if case .preparing = phase { prep?.cancel(); session = UUID(); stopAudio(); Task { [analyzer] in await analyzer?.cancelAndFinishNow() }; reset(); return }
        guard phase == .recording else { if case .failed = phase { removeKeys(); phase = .idle }; return }
        let live = liveTask
        // Where the words go is fixed now, when speaking stops: switching panes while they are written
        // out does not move them.
        let dest = currentTarget
        stopAudio()
        guard insert else { Task { [analyzer] in await analyzer?.cancelAndFinishNow() }; reset(); return }
        phase = .transcribing
        Task {
            let text: String
            await live?.value   // one decode at a time on the Whisper instance
            do {
                if sessionEngine == .whisper, let whisper { text = Self.tidy(try await Self.decode(whisper, samples, final: true)) }
                else { text = Self.tidy(await finishApple()) }
            } catch {
                return fail("Whisper could not write it out: \(error.localizedDescription)")
            }
            if !text.isEmpty { place(text, in: dest) }
            reset()
        }
    }

    private func place(_ text: String, in dest: GhosttyMacView?) {
        if let target = dest, target.window != nil, !target.isHiddenOrHasHiddenAncestor, !target.lost {   // lost: the host went away
            target.window?.makeFirstResponder(target)
            target.pasteText(text)
        } else {
            Platform.pasteString = text
            NSSound.beep()   // ponytail: no toast service on the Mac yet; the overlay already said where it went
        }
    }

    private func fail(_ message: String) { stopAudio(); phase = .failed(message) }

    private func reset() {
        phase = .idle; partial = ""; levels = []; elapsed = 0; finalText = ""; audioStore.clear()
        analyzer = nil; feed = nil; resultsTask?.cancel(); resultsTask = nil
    }

    // MARK: Audio

    private func startAudio() throws {
        audioStore.clear(); levels.removeAll(); partial = ""; finalText = ""
        let input = audio.inputNode
        let format = input.outputFormat(forBus: 0)
        guard let mono16k = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let toWhisper = AVAudioConverter(from: format, to: mono16k) else { throw VoiceError.audioFormat }
        let toApple = appleFormat.flatMap { AVAudioConverter(from: format, to: $0) }
        let appleFormat = appleFormat
        let feed = feed
        let whisperNeedsAudio = sessionEngine == .whisper
        let store = audioStore
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            let level = Self.level(buffer)
            if whisperNeedsAudio { store.append(Self.convert(buffer, with: toWhisper, to: mono16k)) }
            if let toApple, let appleFormat, let out = Self.convertBuffer(buffer, with: toApple, to: appleFormat) { feed?.yield(AnalyzerInput(buffer: out)) }
            Task { @MainActor in VoiceInput.shared.append(level: level) }
        }
        audio.prepare()
        do { try audio.start() } catch { input.removeTap(onBus: 0); throw error }
        installKeys()
        started = Date(); elapsed = 0
        phase = .recording
        clock = Task { while !Task.isCancelled { elapsed = Date().timeIntervalSince(started); try? await Task.sleep(for: .milliseconds(100)) } }
        if sessionEngine == .whisper { liveTask = Task { await whisperLive() } }
    }

    private func stopAudio() {
        if audio.isRunning { audio.inputNode.removeTap(onBus: 0); audio.stop() }
        clock?.cancel(); liveTask?.cancel()
        feed?.finish()
        removeKeys()
    }

    private func append(level: Float) {
        guard phase == .recording else { return }
        levels.append(level)
        if levels.count > 48 { levels.removeFirst(levels.count - 48) }
    }

    /// Return and Esc belong to the overlay while it listens, not to the terminal under it.
    private func installKeys() {
        removeKeys()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            // Only plain Return / Esc, and only in the window that is dictating.
            let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
            guard mods.isEmpty, MainActor.assumeIsolated({ e.window === VoiceInput.shared.window }) else { return e }
            switch e.keyCode {
            case 36, 76:   // Return: only once recording; while preparing it belongs to the focused control
                return MainActor.assumeIsolated {
                    guard VoiceInput.shared.phase == .recording else { return e }
                    VoiceInput.shared.finish(insert: true); return nil
                }
            case 53: MainActor.assumeIsolated { VoiceInput.shared.finish(insert: false) }; return nil
            default: return e
            }
        }
    }
    private func removeKeys() { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }; keyMonitor = nil }

    // MARK: Apple dictation

    /// Builds the analyzer, then keeps it only if `session` is still the current one: an older,
    /// cancelled preparation must not overwrite a newer session's state.
    private func prepareApple(session id: UUID) async throws {
        let locale = await DictationTranscriber.supportedLocale(equivalentTo: .current) ?? Locale(identifier: "en_US")
        let transcriber = DictationTranscriber(locale: locale, preset: .progressiveShortDictation)
        // The language pack downloads once, through macOS, the first time a language is used.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            guard !Task.isCancelled, session == id else { return }   // every await: a newer session may own the state now
            phase = .preparing("Getting the \(locale.localizedString(forIdentifier: locale.identifier) ?? "speech") model from Apple…")
            try await request.downloadAndInstall()
            guard !Task.isCancelled, session == id else { return }
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        guard !Task.isCancelled, session == id else { return }
        appleFormat = format
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        feed = continuation
        self.analyzer = analyzer
        resultsTask = Task {
            do {
                for try await r in transcriber.results {
                    let text = String(r.text.characters)
                    if r.isFinal { finalText += text; partial = finalText } else { partial = finalText + text }
                }
            } catch {}
        }
        try await analyzer.start(inputSequence: stream)
    }

    /// The words so far: finalised text plus the last volatile part. The dictation transcriber does not
    /// always mark its last result final (seen on macOS 26 with a short clip), so final-only would lose it.
    private func finishApple() async -> String {
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        await resultsTask?.value
        return partial
    }

    // MARK: Whisper (optional download)

    private static var whisperBase: URL {
        let dir = (FileManager.default.sidraSupport ?? URL.temporaryDirectory).appending(path: "whisper", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private static var whisperFolder: URL? {
        guard let rel = UserDefaults.standard.string(forKey: "sidra.whisperFolder.\(whisperVariant)") else { return nil }
        let url = whisperBase.appending(path: rel)
        return FileManager.default.fileExists(atPath: url.appending(path: "AudioEncoder.mlmodelc").path) ? url : nil
    }
    /// Whether the Whisper model is on disk; set on download and removal so views follow it.
    private(set) var whisperOnDisk = VoiceInput.whisperFolder != nil

    func downloadWhisper() {
        guard downloadProgress == nil else { return }
        downloadProgress = 0; downloadError = nil
        Task {
            do {
                let folder = try await WhisperKit.download(variant: Self.whisperVariant, downloadBase: Self.whisperBase) { p in
                    Task { @MainActor in VoiceInput.shared.downloadProgress = p.fractionCompleted }
                }
                // Load once while online: WhisperKit fetches the tokenizer then, so later use works offline.
                // Only a model that loaded counts as downloaded.
                downloadProgress = 1
                whisper = try await WhisperKit(WhisperKitConfig(modelFolder: folder.path, tokenizerFolder: Self.whisperBase,
                                                                verbose: false, logLevel: .error, prewarm: false, load: true, download: false))
                let rel = folder.path.replacingOccurrences(of: Self.whisperBase.path + "/", with: "")
                UserDefaults.standard.set(rel, forKey: "sidra.whisperFolder.\(Self.whisperVariant)")
                whisperOnDisk = true
                engine = .whisper
            } catch {
                downloadError = "The Whisper model did not download: \(error.localizedDescription)"
            }
            downloadProgress = nil
        }
    }

    func removeWhisper() {
        guard !isActive else { return }   // a recording may be using it
        whisper = nil
        if let f = Self.whisperFolder { try? FileManager.default.removeItem(at: f) }
        UserDefaults.standard.removeObject(forKey: "sidra.whisperFolder.\(Self.whisperVariant)")
        whisperOnDisk = false
        engine = .apple
    }

    private func loadWhisper() async throws {
        guard whisper == nil, let folder = Self.whisperFolder else { return }
        phase = .preparing("Loading Whisper (the first time compiles it for this Mac)…")
        whisper = try await WhisperKit(WhisperKitConfig(modelFolder: folder.path, tokenizerFolder: Self.whisperBase,
                                                        verbose: false, logLevel: .error, prewarm: false, load: true, download: false))
    }

    private var busy = false
    private func whisperLive() async {
        while !Task.isCancelled, phase == .recording {
            try? await Task.sleep(for: .milliseconds(1200))
            guard phase == .recording, samples.count > 8_000, !busy, let whisper else { continue }
            busy = true
            let text = (try? await Self.decode(whisper, Array(samples.suffix(16_000 * 28)), final: false)) ?? ""
            busy = false
            if phase == .recording, !text.isEmpty { partial = text }
        }
    }

    static func decode(_ whisper: WhisperKit, _ audio: [Float], final: Bool) async throws -> String {
        var padded = audio
        if padded.count < 32_000 { padded += [Float](repeating: 0, count: 32_000 - padded.count) }   // Whisper skips sub-second clips
        let options = DecodingOptions(task: .transcribe, language: nil, temperatureFallbackCount: final ? 2 : 0,
                                      skipSpecialTokens: true, withoutTimestamps: true, suppressBlank: true, chunkingStrategy: final ? .vad : nil)
        let results = try await whisper.transcribe(audioArray: padded, decodeOptions: options)
        return results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Helpers

    /// One line, so a newline can never run it even without bracketed paste; a one-line command does
    /// not end in a full stop.
    static func tidy(_ text: String) -> String {
        var t = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.contains(". "), t.hasSuffix("."), t.count < 80 { t.removeLast() }
        return t
    }

    nonisolated static func level(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let ch = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let rms = vDSP.rootMeanSquare(UnsafeBufferPointer(start: ch, count: Int(buffer.frameLength)))
        let db = 20 * log10(max(rms, 1e-6))
        return min(1, max(0, (db + 55) / 45))
    }

    nonisolated static func convertBuffer(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32) else { return nil }
        var fed = false
        converter.convert(to: out, error: nil) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buffer
        }
        return out
    }

    nonisolated static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat) -> [Float] {
        guard let out = convertBuffer(buffer, with: converter, to: format), let ch = out.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: ch, count: Int(out.frameLength)))
    }

    /// Whisper's audio, appended from the tap's thread under a lock.
    final class SampleStore: @unchecked Sendable {
        private let lock = NSLock(); private var data: [Float] = []
        func append(_ s: [Float]) { lock.withLock { data += s } }
        func clear() { lock.withLock { data = [] } }
        var all: [Float] { lock.withLock { data } }
        var count: Int { lock.withLock { data.count } }
    }

    enum VoiceError: LocalizedError {
        case audioFormat
        var errorDescription: String? { "the microphone format is not supported" }
    }
}
#endif
