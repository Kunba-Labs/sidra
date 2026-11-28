import Foundation
import AVFoundation
import os

/// OpenAI's Live API over a plain WebSocket (no WebRTC, so no new dependency). One JSON text frame per event.
final class LiveSocket: LiveLink, @unchecked Sendable {
    let events: AsyncStream<LiveEvent>
    private let out: AsyncStream<LiveEvent>.Continuation
    private let task: URLSessionWebSocketTask

    init(key: String) {
        var request = URLRequest(url: LiveCodec.url)
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        task = URLSession(configuration: .ephemeral).webSocketTask(with: request)
        task.maximumMessageSize = 16 << 20   // a second of speech arrives in one frame
        (events, out) = AsyncStream.makeStream()
        task.resume()
        receive()
    }

    private func receive() {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.string(let s)): out.yield(LiveCodec.parse(Data(s.utf8))); receive()
            case .success(.data(let d)): out.yield(LiveCodec.parse(d)); receive()
            case .success: receive()
            case .failure(let error):
                // A wrong key ends the handshake with 401: say that, not "socket is not connected".
                let code = (task.response as? HTTPURLResponse)?.statusCode
                out.yield(.closed(code == 401 ? "OpenAI refused the key. Check it in Settings › Voice." : error.localizedDescription))
                out.finish()
            }
        }
    }

    func send(_ json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json), let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { _ in }
    }

    func close() {
        send(LiveCodec.close)
        task.cancel(with: .normalClosure, reason: nil)
        out.finish()
    }
}

/// The microphone in, the voice out: both 24 kHz mono 16-bit, the Live API's default.
@MainActor
final class AssistantAudio {
    private var engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let playFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: LiveCodec.rate, channels: 1, interleaved: false)!
    /// Read on the audio thread: only while it is true do microphone frames leave the device.
    private let capturing = OSAllocatedUnfairLock(initialState: false)
    private(set) var running = false

    /// Microphone frames as 16-bit PCM, on the audio thread.
    var onChunk: (@Sendable (Data) -> Void)?
    /// Loudness 0…1 of what plays or what is said.
    var onLevel: (@MainActor (Double) -> Void)?
    /// Seven bands of the voice, low to high, each 0…1: the microphone's (`mine` true) or what plays now. The orb's lobes follow them.
    var onBands: (@MainActor (_ mine: Bool, _ bands: [Double]) -> Void)?

    func start() throws {
        guard !running else { return }
        #if os(iOS) || os(visionOS)
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker])
        try s.setActive(true)
        #endif
        #if os(macOS)
        engine = AVAudioEngine()
        #endif
        MicInputs.apply(to: engine)
        let input = engine.inputNode
        // The microphone stays open while the voice speaks: the system's echo canceller keeps the voice out of it.
        try? input.setVoiceProcessingEnabled(true)
        let format = input.inputFormat(forBus: 0)
        guard let wire = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: LiveCodec.rate, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: format, to: wire) else { throw VoiceInput.VoiceError.audioFormat }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)
        let capturing = capturing, onChunk = onChunk
        input.installTap(onBus: 0, bufferSize: 2400, format: format) { [weak self] buffer, _ in
            guard capturing.withLock({ $0 }), let out = VoiceInput.convertBuffer(buffer, with: converter, to: wire), let p = out.int16ChannelData?[0] else { return }
            let n = Int(out.frameLength)
            onChunk?(Data(bytes: p, count: n * 2))
            let s = UnsafeBufferPointer(start: p, count: n)
            let level = Self.level(s), bands = Self.bands(s.suffix(VoiceInput.fftSize).map { Float($0) / 32768 })
            Task { @MainActor in self?.onLevel?(level); self?.onBands?(true, bands) }
        }
        // What plays now, not what arrived: the service sends speech faster than it sounds.
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            guard let ch = buffer.floatChannelData?[0] else { return }
            let bands = Self.bands(Array(UnsafeBufferPointer(start: ch, count: Int(buffer.frameLength)).suffix(VoiceInput.fftSize)))
            Task { @MainActor in self?.onBands?(false, bands) }
        }
        engine.prepare()
        try engine.start()
        player.play()
        running = true
    }

    func stop() {
        guard running else { return }
        running = false
        capturing.withLock { $0 = false }
        engine.inputNode.removeTap(onBus: 0); engine.mainMixerNode.removeTap(onBus: 0)
        player.stop(); engine.stop(); engine.detach(player)
        #if os(iOS) || os(visionOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    func listen(_ on: Bool) { capturing.withLock { $0 = on } }

    /// Talking over the voice stops it: what it still had queued is dropped.
    func interrupt() { if running { player.stop(); player.play() } }

    func play(_ pcm: Data) {
        guard running, let buffer = Self.buffer(pcm, format: playFormat) else { return }
        onLevel?(pcm.withUnsafeBytes { Self.level($0.bindMemory(to: Int16.self)) })
        player.scheduleBuffer(buffer)
    }

    nonisolated static func buffer(_ pcm: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let n = pcm.count / 2
        guard n > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)), let out = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(n)
        pcm.withUnsafeBytes { raw in
            let s = raw.bindMemory(to: Int16.self)
            for i in 0..<n { out[i] = Float(Int16(littleEndian: s[i])) / 32768 }
        }
        return buffer
    }

    /// Seven bands from dictation's 48-bin spectrum (80 Hz to 8 kHz, log spaced). Silence reads as zeros.
    nonisolated static func bands(_ frame: [Float]) -> [Double] {
        guard frame.count == VoiceInput.fftSize, frame.contains(where: { abs($0) > 0.004 }) else { return [Double](repeating: 0, count: 7) }
        let bins = VoiceInput.spectrum(frame)
        return (0..<7).map { b in
            let part = bins[(b * bins.count / 7)..<((b + 1) * bins.count / 7)]
            return Double(part.reduce(0, +)) / Double(max(1, part.count))
        }
    }

    /// Root mean square on a scale where speech sits around 0.3 to 0.8.
    nonisolated static func level(_ s: UnsafeBufferPointer<Int16>) -> Double {
        guard !s.isEmpty else { return 0 }
        var sum = 0.0
        for v in s { let f = Double(v) / 32768; sum += f * f }
        return min(1, (sum / Double(s.count)).squareRoot() * 5)
    }
}
