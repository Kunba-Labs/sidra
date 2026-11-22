#if os(iOS)
import UIKit

/// Swipe typing: turn a finger path over the letter keys into words. Candidates come from iOS's own
/// dictionary (UITextChecker completions, most likely first), so no word list ships with Sidra and other
/// languages are a matter of passing their code. Each candidate's ideal path (key centre to key centre)
/// is compared point by point with the swipe; the closest shapes win, nudged by how common the word is.
enum SwipeTyping {
    static let samples = 48

    /// Best words first. `keys` maps "a"…"z" to key centres in the same space as `path`;
    /// `keyWidth` scales distances so a sloppy swipe on a big keyboard scores like one on a small one.
    /// `after`: the word before, for how often you follow it with each candidate (WordModel).
    @MainActor static func decode(_ path: [CGPoint], keys: [Character: CGPoint], keyWidth: CGFloat, language: String = "en_US", limit: Int = 4, used: [String: Int] = [:], after prev: String? = nil) -> [String] {
        let model = WordModel.shared
        guard path.count >= 2, keyWidth > 0, !keys.isEmpty else { return [] }
        let swipe = resample(path, samples)
        let swipeLength = length(path)
        let near = { (p: CGPoint, n: Int) in keys.sorted { dist($0.value, p) < dist($1.value, p) }.prefix(n).map(\.key) }
        let starts = near(path[0], 2), ends = Set(near(path[path.count - 1], 3))
        // Letters the finger passed close to, in order: these seed the two-letter prefixes.
        var passed: [Character] = []
        for p in swipe { if let k = near(p, 1).first, dist(keys[k]!, p) < keyWidth * 0.9, passed.last != k { passed.append(k) } }

        var pool: [String: Int] = [:]   // word → rank in iOS's list (lower is more likely)
        let checker = UITextChecker()
        for s in starts {
            // Prefixes of the start key plus one or two keys the path passed later, in order. iOS caps each
            // completion list, so narrower three-letter prefixes are what reach the less common words.
            var prefixes = Set([String(s)])
            let after = Array(passed.drop { $0 == s })
            for (i, c1) in after.enumerated() {
                prefixes.insert(String([s, c1]))
                for c2 in after[i...] { prefixes.insert(String([s, c1, c2])) }   // c2 == c1 covers double letters ("hello")
            }
            for prefix in prefixes {
                let words = checker.completions(forPartialWordRange: NSRange(location: 0, length: prefix.utf16.count), in: prefix, language: language) ?? []
                for (i, w) in words.enumerated() {
                    let lw = w.lowercased()
                    guard lw.count >= 2, lw.allSatisfy({ keys[$0] != nil }), let last = lw.last, ends.contains(last) else { continue }
                    pool[lw] = min(pool[lw] ?? .max, i)
                }
            }
            // Words swiped before join even when iOS's list leaves them out (names, jargon).
            // Your own words (Theasa prompts, lines you sent) join the same way, ranked mid-list unless iOS knows them.
            for w in model.words(startingWith: s, endingIn: ends) where w.allSatisfy({ keys[$0] != nil }) { pool[w] = min(pool[w] ?? .max, 30) }
            for (w, _) in used where w.first == s && w.count >= 2 && w.allSatisfy({ keys[$0] != nil }) && ends.contains(w.last!) { pool[w] = min(pool[w] ?? .max, 0) }
            if s == "a" || s == "i", let one = keys[s], dist(one, path[path.count - 1]) < keyWidth { pool[String(s)] = 0 }   // the one-letter words
        }

        let scored = pool.compactMap { word, rank -> (String, Double)? in
            var letters: [CGPoint] = []
            for ch in word { let p = keys[ch]!; if letters.last != p { letters.append(p) } }
            guard letters.count >= 1 else { return nil }
            let ideal = resample(letters.count == 1 ? [letters[0], letters[0]] : letters, samples)
            var d = 0.0
            for i in 0..<samples { d += Double(dist(ideal[i], swipe[i])) }
            let shape = d / Double(samples) / Double(keyWidth)
            // A word whose key path is much longer or shorter than the swipe is the wrong word, however
            // similar the shapes (real swipes of "should" decoded as "feudalist" without this).
            let idealLength = max(length(letters), keyWidth * 0.5)
            let stretch = abs(log(Double(max(swipeLength, keyWidth * 0.5) / idealLength)))
            // Each use pulls a word up, less and less: picked once from the alternatives (3) is worth about
            // half a key's width of shape error.
            // How much you use the word, and how often it follows the previous one: "pull request" over "pull requite".
            let habit = 0.3 * log(Double(used[word] ?? 0) + 1) + 0.06 * log(Double(model.count(word)) + 1)
                + 0.25 * log(Double(model.follows(word, after: prev)) + 1)
            return (word, shape + 0.9 * stretch + 0.12 * log(Double(rank) + 1) - habit)
        }
        return scored.sorted { $0.1 < $1.1 }.prefix(limit).map(\.0)
    }

    /// `n` points spaced evenly along the polyline.
    static func resample(_ pts: [CGPoint], _ n: Int) -> [CGPoint] {
        guard pts.count > 1 else { return Array(repeating: pts.first ?? .zero, count: n) }
        var lengths = [CGFloat(0)]
        for i in 1..<pts.count { lengths.append(lengths[i - 1] + dist(pts[i - 1], pts[i])) }
        let total = lengths.last!
        guard total > 0 else { return Array(repeating: pts[0], count: n) }
        var out: [CGPoint] = [], j = 1
        for k in 0..<n {
            let target = total * CGFloat(k) / CGFloat(n - 1)
            while j < pts.count - 1, lengths[j] < target { j += 1 }
            let seg = lengths[j] - lengths[j - 1], t = seg > 0 ? (target - lengths[j - 1]) / seg : 0
            out.append(CGPoint(x: pts[j - 1].x + (pts[j].x - pts[j - 1].x) * t, y: pts[j - 1].y + (pts[j].y - pts[j - 1].y) * t))
        }
        return out
    }

    static func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    static func length(_ pts: [CGPoint]) -> CGFloat {
        zip(pts, pts.dropFirst()).reduce(0) { $0 + dist($1.0, $1.1) }
    }
}
#endif
