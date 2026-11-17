import SwiftUI
import FoundationModels
import SidraDesign

@Generable struct ThreadNote {
    @Guide(description: "The thread number, as given in the input") var thread: Int
    @Guide(description: "One short sentence of at most 20 words: the specific claim the thread makes, and whether the replies agree or dispute it") var point: String
}
@Generable struct ThreadNotes {
    @Guide(description: "One note for each thread in the input") var notes: [ThreadNote]
}
@Generable struct Digest {
    @Guide(description: "Two short sentences on what commenters conclude and where they disagree. Name the specific topics; do not describe the discussion in general terms") var overview: String
    @Guide(description: "The three most important points, each from a different thread", .count(3)) var points: [ThreadNote]
}

struct ThreadSummary: Codable {
    struct Point: Codable, Hashable { var text: String; var comment: Int }
    var overview: String
    var points: [Point]
    var comments: Int
    var seconds: Int
}

/// Summarises a discussion with the on-device model. Nothing leaves the device.
/// The model's context is small, so threads are summarised in groups and the notes are then combined.
@MainActor @Observable final class Summarizer {
    /// waiting: the on-device model is still downloading; the summary starts by itself once it is there.
    enum Phase: Equatable { case idle, waiting, running(Int, Int), ready, unavailable(String), failed(String) }
    var phase: Phase = .idle
    var result: ThreadSummary?
    private var task: Task<Void, Never>?

    private static let rules = "You summarise Hacker News discussion threads. Be specific and neutral. Use plain words. Do not address the reader."
    private static let maxThreads = 60      // ponytail: HN ranks the best threads first; the rest are left out
    private static let threadChars = 1200
    private static let chunkChars = 5000    // about 1,500 tokens of a 4,096-token context

    private func file(_ id: Int) -> URL {
        URL.sidraCaches.appending(path: "hackertab-summary-\(id).json")
    }

    func cancel() {
        task?.cancel()
        task = nil
        phase = .idle
        result = nil
    }

    func start(story: Story, comments: [Comment]) {
        cancel()
        guard comments.count >= 8 else { return }   // short threads are quicker to read than to summarise
        result = (try? Data(contentsOf: file(story.id))).flatMap { try? JSONDecoder().decode(ThreadSummary.self, from: $0) }
        // A saved summary is still good until at least five comments have been added.
        if let r = result, abs(comments.count - r.comments) < 5 { phase = .ready; return }
        switch SystemLanguageModel.default.availability {
        case .available: break
        case .unavailable(.deviceNotEligible): phase = .unavailable("this device has no on-device model"); return
        case .unavailable(.appleIntelligenceNotEnabled): phase = .unavailable("turn on Apple Intelligence in Settings"); return
        case .unavailable(.modelNotReady):
            // Apple's API gives no download progress; look again every 5 s and start when the model is in.
            phase = .waiting
            task = Task {
                while true {
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }   // cancelled: another story, or closed
                    guard !Task.isCancelled else { return }
                    switch SystemLanguageModel.default.availability {
                    case .available: await run(story: story, comments: comments); return
                    case .unavailable(.modelNotReady): continue
                    case .unavailable(.appleIntelligenceNotEnabled): phase = .unavailable("turn on Apple Intelligence in Settings"); return
                    case .unavailable(.deviceNotEligible): phase = .unavailable("this device has no on-device model"); return
                    case .unavailable: phase = .unavailable("the on-device model is not available"); return
                    }
                }
            }
            return
        case .unavailable: phase = .unavailable("the on-device model is not available"); return
        }
        task = Task { await run(story: story, comments: comments) }
    }

    private func run(story: Story, comments: [Comment]) async {
        let began = Date()
        let roots = Array(comments.indices.filter { comments[$0].depth == 0 }.prefix(Self.maxThreads))
        let texts = roots.enumerated().map { n, i in
            let body = comments[i...(i + comments[i].subtree)].map { "\($0.author): \($0.plain)" }.joined(separator: "\n")
            return "Thread \(n + 1)\n" + body.prefix(Self.threadChars)
        }
        var chunks: [[String]] = [[]]
        for t in texts {
            if !chunks[chunks.count - 1].isEmpty && chunks[chunks.count - 1].reduce(0, { $0 + $1.count }) + t.count > Self.chunkChars { chunks.append([]) }
            chunks[chunks.count - 1].append(t)
        }
        phase = .running(0, roots.count)
        var notes: [ThreadNote] = []
        var done = 0
        var lastError = "no summary was produced"
        for chunk in chunks {
            if Task.isCancelled { return }
            do {
                let prompt = "These are threads from the Hacker News discussion of \"\(story.title)\". Write one note for each thread.\n\n" + chunk.joined(separator: "\n\n")
                notes += try await LanguageModelSession(instructions: Self.rules).respond(to: prompt, generating: ThreadNotes.self).content.notes
            } catch {
                // One group can fail (a safety refusal, for example); the others still make a summary.
                lastError = error.localizedDescription
            }
            if Task.isCancelled { return }
            done += chunk.count
            phase = .running(done, roots.count)
        }
        do {
            guard !notes.isEmpty else { phase = .failed(lastError); return }
            let list = notes.map { "Thread \($0.thread): \($0.point)" }.joined(separator: "\n").prefix(Self.chunkChars + 1000)
            let prompt = "These are notes on the threads of the Hacker News discussion of \"\(story.title)\". Summarise the discussion.\n\n" + list
            let d = try await LanguageModelSession(instructions: Self.rules).respond(to: prompt, generating: Digest.self).content
            if Task.isCancelled { return }
            let points = d.points.compactMap { n in
                roots.indices.contains(n.thread - 1) ? ThreadSummary.Point(text: n.point, comment: comments[roots[n.thread - 1]].id) : nil
            }
            let s = ThreadSummary(overview: d.overview, points: points, comments: comments.count, seconds: Int(Date().timeIntervalSince(began)))
            result = s
            phase = .ready
            try? JSONEncoder().encode(s).write(to: file(story.id))
        } catch {
            if !Task.isCancelled { phase = .failed(error.localizedDescription) }
        }
    }
}
