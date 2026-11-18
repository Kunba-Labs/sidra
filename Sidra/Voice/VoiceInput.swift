#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import AVFoundation
import Accelerate
import Speech
import Observation
import SidraDesign
import SidraTerminal
import WhisperKit

#if os(macOS)
typealias DictationSurface = GhosttyMacView
#else
typealias DictationSurface = GhosttyTerminalView
#endif

/// Hold-to-talk dictation into the focused terminal, on iPad and Mac: hold the floating green mic, speak,
/// release to insert the words at the cursor (one line, so nothing runs), slide left to cancel. Speech
/// becomes text on the device: Apple's dictation model by default, or Whisper large-v3 once its model is
/// downloaded (Settings → Voice; 626 MB, optional). On the Mac ⌥⌘V toggles it too (Return inserts, Esc drops).
@MainActor @Observable
final class VoiceInput {
    static let shared = VoiceInput()

    enum Engine: String, CaseIterable { case apple, whisper }
    enum Phase: Equatable {
        case idle
        case preparing(String)       // the microphone prompt, a language pack or the Whisper model loading
        case recording
        case transcribing
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// Words heard so far: Apple's volatile results, or Whisper's live pass.
    private(set) var partial = ""
    private(set) var elapsed: TimeInterval = 0
    /// Spectrogram columns, newest last; each `bins` magnitudes 0…1, low frequencies first.
    private(set) var columns: [[Float]] = []
    nonisolated static let bins = 48
    static let maxColumns = 160
    /// Slid left far enough while held: release drops the words.
    var cancelling = false
    /// Whisper model download progress, 0…1; nil when not downloading.
    private(set) var downloadProgress: Double?
    var downloadError: String?

    /// Observable, so Settings updates at once; persisted for the next launch.
    var engine: Engine = Engine(rawValue: UserDefaults.standard.string(forKey: "sidra.voiceEngine") ?? "") ?? .apple {
        didSet { UserDefaults.standard.set(engine.rawValue, forKey: "sidra.voiceEngine") }
    }
    /// Whisper only once its model is on disk; Apple otherwise.
    private var activeEngine: Engine { engine == .whisper && whisperOnDisk ? .whisper : .apple }

    private var audio = AVAudioEngine()
    /// 16 kHz mono, written from the microphone's thread, so a buffer on its way when recording stops is
    /// not dropped. Whisper reads all of it; the spectrogram its newest frames.
    private let audioStore = SampleStore()
    private var started = Date()
    private var clock: Task<Void, Never>?
    private var liveTask: Task<Void, Never>?
    private var fftWindow: [Float] = []
    #if os(macOS)
    private var keyMonitor: Any?
    /// The window dictating; its terminal is looked up when speaking stops.
    private(set) var window: NSWindow?
    #else
    private(set) var window: UIWindow?
    #endif

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

    /// The engine this recording uses, fixed at start: a settings change mid-recording does not switch it.
    private var sessionEngine: Engine = .apple
    private var prep: Task<Void, Never>?
    private var session = UUID()
    /// The mic is held down: preparation that ends after release does not open the microphone.
    private var held = false

    var isActive: Bool { phase != .idle }
    /// Preparing or writing out: the mic has nothing to do until that ends.
    var isBusy: Bool { if case .preparing = phase { true } else { phase == .transcribing } }

    // MARK: Target

    /// The terminal focused in the dictating window, or the one that last had focus there. Hidden
    /// terminals (another tab) and lost ones do not count. Nil: the words go to the clipboard.
    var currentTarget: DictationSurface? {
        guard let w = window else { return nil }
        #if os(macOS)
        let t = (w.firstResponder as? GhosttyMacView) ?? GhosttyMacView.lastFocused.flatMap { $0.window === w ? $0 : nil }
        return t.flatMap { $0.isHiddenOrHasHiddenAncestor || $0.lost ? nil : $0 }
        #else
        let t = GhosttyTerminalView.lastFocused.flatMap { $0.window === w ? $0 : nil }
        return t.flatMap { $0.isHidden || $0.lost ? nil : $0 }
        #endif
    }
    var hasTarget: Bool { currentTarget != nil }

    // MARK: Hold to talk

    /// The mic went down: get ready and listen while it stays down.
    func press(in window: PlatformWindow? = nil) {
        switch phase {
        case .idle, .failed: break
        default: return
        }
        held = true
        start(in: window)
    }

    /// The mic came up: insert what was said, or drop it. Up while still getting ready (the microphone
    /// prompt, a model download, the first load): the setup finishes anyway, without opening the
    /// microphone, so the next hold starts at once. Esc is the way to stop a setup.
    func release(cancel: Bool) {
        held = false
        if case .preparing = phase { cancelling = false; return }
        finish(insert: !cancel)
        cancelling = false
    }

    /// ⌥⌘V on the Mac: start, or insert what was said.
    func toggle() {
        #if os(macOS)
        // From another window: show the one that is dictating rather than finish its recording.
        if isActive, let w = window, NSApp.keyWindow !== w { w.makeKeyAndOrderFront(nil); return }
        #endif
        switch phase {
        case .recording: finish(insert: true)
        case .idle, .failed: held = true; start(in: nil)
        default: break
        }
    }

    private func start(in w: PlatformWindow?) {
        #if os(macOS)
        window = w ?? NSApp.keyWindow
        #else
        window = w ?? GhosttyTerminalView.lastFocused?.window
        #endif
        sessionEngine = activeEngine
        let id = UUID(); session = id
        phase = .preparing("Getting ready…")
        installKeys()   // Esc cancels while preparing too
        prep = Task {
            let allowed = await AVAudioApplication.requestRecordPermission()
            guard !Task.isCancelled, session == id else { return }   // cancelled during the prompt
            guard allowed else {
                #if os(macOS)
                return fail("Sidra may not use the microphone. Allow it in System Settings → Privacy & Security → Microphone.")
                #else
                return fail("Sidra may not use the microphone. Turn it on in Settings › Sidra › Microphone.")
                #endif
            }
            do {
                if sessionEngine == .whisper { try await loadWhisper(session: id) } else { try await prepareApple(session: id) }
                // Cancelled, released, or a newer start took over while this was loading: no microphone.
                guard !Task.isCancelled, session == id, held, case .preparing = phase else {
                    if session == id, !held { cleanUp(); reset() }
                    return
                }
                try startAudio()
            } catch {
                if session == id, !Task.isCancelled { fail("Could not start listening: \(error.localizedDescription)") }
            }
        }
    }

    /// Release, Return or the key again: insert. Slide left, Esc: drop.
    func finish(insert: Bool) {
        if case .preparing = phase {
            if insert, held { return }                  // ⌥⌘V / Return while preparing: wait for it
            prep?.cancel(); session = UUID(); cleanUp(); reset(); return
        }
        if phase == .transcribing, !insert { session = UUID(); cleanUp(); reset(); return }   // stop waiting for the words
        guard phase == .recording else { if case .failed = phase { removeKeys(); phase = .idle }; return }
        let live = liveTask
        // Where the words go is fixed now, when speaking stops: switching panes while they are written
        // out does not move them.
        let dest = currentTarget
        stopAudio()
        guard insert else { cleanUp(); reset(); return }
        phase = .transcribing
        let id = session
        Task {
            let text: String
            await live?.value   // one decode at a time on the Whisper instance
            do {
                if sessionEngine == .whisper, let whisper { text = Self.tidy(try await Self.decode(whisper, audioStore.all, final: true)) }
                else { text = Self.tidy(await finishApple()) }
            } catch {
                guard session == id else { return }
                return fail("Whisper could not write it out: \(error.localizedDescription)")
            }
            guard session == id else { return }   // cancelled while writing out
            if !text.isEmpty { place(text, in: dest) }
            reset()
        }
    }

    func dismissMessage() { if case .failed = phase { removeKeys(); phase = .idle } }

    /// The card's close button: drop whatever stage this is at, nothing is inserted.
    func cancel() {
        held = false; cancelling = false
        if case .failed = phase { dismissMessage() } else { finish(insert: false) }
    }

    /// Another microphone from the card: remembered for next time; a recording starts over on it, as
    /// what the old one heard is usually why it was switched.
    func useMic(_ uid: String?) {
        MicInputs.chosen = uid
        guard phase == .recording else { return }
        let w = window
        session = UUID(); cleanUp(); reset()
        held = true
        start(in: w)
    }

    private func place(_ text: String, in dest: DictationSurface?) {
        #if os(macOS)
        if let t = dest, t.window != nil, !t.isHiddenOrHasHiddenAncestor, !t.lost {
            t.window?.makeFirstResponder(t)
            t.pasteText(text)
        } else {
            Platform.pasteString = text
            NSSound.beep()   // ponytail: no toast service on the Mac yet; the card said where it would go
        }
        #else
        if let t = dest, t.window != nil, !t.isHidden, !t.lost {
            t.pasteText(text)
            t.offerSend()   // dictated text waits for a Send tap, as on the keyboard's mic
        } else {
            Platform.pasteString = text
        }
        #endif
    }

    /// Stops everything this session started (audio, the Apple analyzer and its results), so a retry
    /// starts clean, then shows why.
    private func fail(_ message: String) {
        cleanUp()
        partial = ""; finalText = ""
        phase = .failed(message)
    }

    private func cleanUp() {
        stopAudio()
        resultsTask?.cancel(); resultsTask = nil
        Task { [analyzer] in await analyzer?.cancelAndFinishNow() }
        analyzer = nil; feed = nil; appleFormat = nil
    }

    private func reset() {
        phase = .idle; partial = ""; columns = []; elapsed = 0; finalText = ""; cancelling = false
        audioStore.clear(); fftWindow = []
        analyzer = nil; feed = nil; resultsTask?.cancel(); resultsTask = nil
        removeKeys()
    }

    // MARK: Audio

    private func startAudio() throws {
        audioStore.clear(); columns.removeAll(); fftWindow.removeAll(); partial = ""; finalText = ""
        #if os(iOS)
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try s.setActive(true)
        #endif
        #if os(macOS)
        audio = AVAudioEngine()   // nothing carried over from the last device
        #endif
        MicInputs.apply(to: audio)   // the microphone picked in Settings → Voice or on the card
        let input = audio.inputNode
        // The device's own format: after the device is switched, the node's output format still describes
        // the default device, and a tap in that format gets nothing (seen with a 2-channel webcam mic).
        let format = input.inputFormat(forBus: 0)
        guard let mono16k = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let to16k = AVAudioConverter(from: format, to: mono16k) else { throw VoiceError.audioFormat }
        let toApple = appleFormat.flatMap { AVAudioConverter(from: format, to: $0) }
        // Apple's engine needs its converter; without it nothing would reach the analyzer.
        if sessionEngine == .apple, toApple == nil { throw VoiceError.audioFormat }
        let appleFormat = appleFormat, feed = feed, store = audioStore
        let keepAudio = sessionEngine == .whisper   // Apple reads the stream itself; only Whisper needs the recording
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            let pcm = Self.convert(buffer, with: to16k, to: mono16k)
            if keepAudio { store.append(pcm) }
            if let toApple, let appleFormat, let out = Self.convertBuffer(buffer, with: toApple, to: appleFormat) { feed?.yield(AnalyzerInput(buffer: out)) }
            Task { @MainActor in VoiceInput.shared.spectrum(pcm) }
        }
        audio.prepare()
        do { try audio.start() } catch {
            input.removeTap(onBus: 0)
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            #endif
            throw error
        }
        started = Date(); elapsed = 0
        phase = .recording
        clock = Task { while !Task.isCancelled { elapsed = Date().timeIntervalSince(started); try? await Task.sleep(for: .milliseconds(100)) } }
        if sessionEngine == .whisper { liveTask = Task { await whisperLive() } }
    }

    private func stopAudio() {
        if audio.isRunning {
            audio.inputNode.removeTap(onBus: 0); audio.stop()
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            #endif
        }
        clock?.cancel(); liveTask?.cancel()
        feed?.finish()
    }

    private func spectrum(_ pcm: [Float]) {
        guard phase == .recording else { return }
        fftWindow += pcm
        while fftWindow.count >= Self.fftSize {
            columns.append(Self.spectrum(Array(fftWindow.prefix(Self.fftSize))))
            fftWindow.removeFirst(Self.fftSize / 2)
            if columns.count > Self.maxColumns { columns.removeFirst(columns.count - Self.maxColumns) }
        }
    }

    #if os(macOS)
    /// ⌥⌘V: Return and Esc belong to the card while it listens, not to the terminal under it; only plain
    /// keys, only in the dictating window.
    private func installKeys() {
        removeKeys()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
            guard mods.isEmpty, MainActor.assumeIsolated({ e.window === VoiceInput.shared.window }) else { return e }
            switch e.keyCode {
            case 36, 76:   // Return: only once recording; while preparing it belongs to the focused control
                return MainActor.assumeIsolated {
                    guard VoiceInput.shared.phase == .recording else { return e }
                    VoiceInput.shared.finish(insert: true); return nil
                }
            case 53: MainActor.assumeIsolated { VoiceInput.shared.held = false; VoiceInput.shared.finish(insert: false) }; return nil
            default: return e
            }
        }
    }
    private func removeKeys() { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }; keyMonitor = nil }
    #else
    private func installKeys() {}
    private func removeKeys() {}
    #endif

    // MARK: Apple dictation

    /// Builds the analyzer, then keeps it only if `session` is still the current one: an older,
    /// cancelled preparation must not overwrite a newer session's state.
    private func prepareApple(session id: UUID) async throws {
        let locale = await DictationTranscriber.supportedLocale(equivalentTo: .current) ?? Locale(identifier: "en_US")
        guard !Task.isCancelled, session == id else { return }
        let transcriber = DictationTranscriber(locale: locale, preset: .progressiveShortDictation)
        // The language pack downloads once, through the system, the first time a language is used.
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
    /// It can hang (seen with a silent microphone), so it gives up after 6 s with what it has.
    private func finishApple() async -> String {
        final class Flag { var done = false }
        let flag = Flag(), analyzer = analyzer, results = resultsTask
        Task { @MainActor in
            try? await analyzer?.finalizeAndFinishThroughEndOfInput()
            await results?.value
            flag.done = true
        }
        for _ in 0..<60 where !flag.done { try? await Task.sleep(for: .milliseconds(100)) }
        if !flag.done { cleanUp() }
        return partial
    }

    // MARK: Whisper (optional download)

    private static var whisperBase: URL {
        let dir = (FileManager.default.sidraSupport ?? URL.temporaryDirectory).appending(path: "whisper", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        #if os(iOS)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var d = dir; try? d.setResourceValues(values)
        #endif
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

    private func loadWhisper(session id: UUID) async throws {
        guard whisper == nil, let folder = Self.whisperFolder else { return }
        phase = .preparing("Loading Whisper (the first time compiles it for this device)…")
        let w = try await WhisperKit(WhisperKitConfig(modelFolder: folder.path, tokenizerFolder: Self.whisperBase,
                                                      verbose: false, logLevel: .error, prewarm: false, load: true, download: false))
        if whisper == nil { whisper = w }   // loaded either way; a newer session uses the same instance
        _ = id
    }

    private var busy = false
    private func whisperLive() async {
        while !Task.isCancelled, phase == .recording {
            try? await Task.sleep(for: .milliseconds(1200))
            guard phase == .recording, audioStore.count > 8_000, !busy, let whisper else { continue }
            busy = true
            let text = (try? await Self.decode(whisper, Array(audioStore.all.suffix(16_000 * 28)), final: false)) ?? ""
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

    nonisolated static let fftSize = 512
    nonisolated(unsafe) private static let fft = vDSP.FFT(log2n: 9, radix: .radix2, ofType: DSPSplitComplex.self)!
    nonisolated private static let hann = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: fftSize, isHalfWindow: false)

    /// Magnitudes on a log-frequency axis from ~80 Hz to 8 kHz, in decibels mapped to 0…1.
    nonisolated static func spectrum(_ frame: [Float]) -> [Float] {
        let windowed = vDSP.multiply(frame, hann)
        var real = [Float](repeating: 0, count: fftSize / 2), imag = real
        var mags = [Float](repeating: 0, count: fftSize / 2)
        real.withUnsafeMutableBufferPointer { r in
            imag.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                windowed.withUnsafeBufferPointer { w in
                    w.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(fftSize / 2)) }
                }
                fft.forward(input: split, output: &split)
                vDSP.absolute(split, result: &mags)
            }
        }
        let half = fftSize / 2   // bin k is k * 31.25 Hz at 16 kHz
        return (0..<bins).map { b in
            let lo = 80 * pow(100, Float(b) / Float(bins)), hi = 80 * pow(100, Float(b + 1) / Float(bins))
            let a = max(1, Int(lo / 31.25)), z = min(half - 1, max(a, Int(hi / 31.25)))
            let m = mags[a...z].max() ?? 0
            let db = 20 * log10(max(m, 1e-6))
            return min(1, max(0, (db + 10) / 60))
        }
    }

    /// The recording's 16 kHz audio, appended from the tap's thread under a lock.
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

#if os(macOS)
typealias PlatformWindow = NSWindow
#else
typealias PlatformWindow = UIWindow
#endif
