import Foundation
import Observation
import SidraTheasa
#if canImport(UIKit)
import UIKit
#endif

/// Your own words: how often each comes and which word follows which, learned from your Theasa prompts
/// and every line you send with Sidra's keyboard or voice (Waseem, 2026-11-22). Swipe typing ranks its
/// candidates with it; voice gets your project words (the ones a dictionary lacks) as hints.
/// Kept on this device only, in Application Support.
@MainActor final class WordModel {
    static let shared = WordModel()

    private struct Store: Codable {
        var words: [String: Int] = [:]
        var pairs: [String: [String: Int]] = [:]   // word → the words that followed it
        var theasaTurns: Set<Int> = []             // prompts already learned
        var theasaAt: Date?
    }
    private var store: Store
    private let file: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Sidra/words.json")
    private var saveTask: Task<Void, Never>?

    private init() {
        store = file.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(Store.self, from: $0) } ?? Store()
    }

    /// Lowercase words of letters (and inner apostrophes), in order, per sentence.
    nonisolated static func sentences(_ text: String) -> [[String]] {
        text.lowercased().split(whereSeparator: { ".!?\n".contains($0) }).map { s in
            s.split(whereSeparator: { !($0.isLetter || $0 == "'") }).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
                .filter { $0.count >= 1 && $0.count <= 30 }
        }
    }

    func learn(_ text: String) {
        for s in Self.sentences(text) {
            for (i, w) in s.enumerated() {
                store.words[w, default: 0] += 1
                if i > 0 { store.pairs[s[i - 1], default: [:]][w, default: 0] += 1 }
            }
        }
        scheduleSave()
    }

    func count(_ word: String) -> Int { store.words[word] ?? 0 }
    func follows(_ word: String, after prev: String?) -> Int { prev.flatMap { store.pairs[$0]?[word] } ?? 0 }

    /// Known words starting with `first` and ending in one of `ends`: swipe candidates the dictionary may lack.
    func words(startingWith first: Character, endingIn ends: Set<Character>) -> [String] {
        store.words.keys.filter { $0.count >= 2 && $0.first == first && $0.last.map(ends.contains) == true }
    }

    /// The words worth hinting to voice recognition: frequent ones the system dictionary does not know
    /// (project names, tools, jargon), most used first.
    func projectWords(_ limit: Int = 100) -> [String] {
        let frequent = store.words.filter { $0.value >= 2 && $0.key.count >= 3 }.sorted { $0.value > $1.value }.map(\.key)
        #if canImport(UIKit)
        let checker = UITextChecker()
        let unknown = frequent.filter { w in
            checker.rangeOfMisspelledWord(in: w, range: NSRange(location: 0, length: w.utf16.count), startingAt: 0, wrap: false, language: "en_US").location != NSNotFound
        }
        return Array(unknown.prefix(limit))
        #else
        return Array(frequent.prefix(limit))
        #endif
    }

    /// Your prompts from the active Theasa server, once a day: the last 30 days of every project.
    func refreshFromTheasa() async {
        guard store.theasaAt.map({ Date().timeIntervalSince($0) > 24 * 3600 }) ?? true,
              let client = TheasaStore.shared.activeLive?.client,
              let projects = try? await client.get("/api/projects?range=30d", as: [ProjectRow].self) else { return }
        for p in projects.prefix(40) {
            guard let d = try? await client.get("/api/projects/\(p.id)?range=30d", as: ProjectDetail.self) else { continue }
            for t in d.turns where !store.theasaTurns.contains(t.id) {
                store.theasaTurns.insert(t.id)
                learn(t.prompt)
            }
        }
        store.theasaAt = Date()
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled, let file = self.file else { return }
            self.prune()
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(self.store).write(to: file, options: .atomic)
        }
    }

    /// Caps the file: the 20,000 most used words, 40 followers each.
    // ponytail: a plain cap; a decaying count if old habits should fade
    private func prune() {
        if store.words.count > 20_000 {
            let keep = Set(store.words.sorted { $0.value > $1.value }.prefix(20_000).map(\.key))
            store.words = store.words.filter { keep.contains($0.key) }
            store.pairs = store.pairs.filter { keep.contains($0.key) }
        }
        for (w, f) in store.pairs where f.count > 40 {
            store.pairs[w] = Dictionary(uniqueKeysWithValues: f.sorted { $0.value > $1.value }.prefix(40).map { ($0.key, $0.value) })
        }
    }
}
