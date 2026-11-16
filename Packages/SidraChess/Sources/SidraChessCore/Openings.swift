//  The opening book: Resources/openings.tsv is the Lichess opening list
//  (github.com/lichess-org/chess-openings), released CC0, copied from checkerspromax.
//  It names the opening on screen and gives the engine book moves at Club and up.

import Foundation

public struct Opening: Equatable, Sendable {
    public var eco: String
    public var name: String
    public var sans: [String]
}

public final class Openings: @unchecked Sendable {
    public static let shared = Openings()
    private var byLine: [String: Opening] = [:]
    private var all: [Opening] = []

    private init() {
        guard let url = Bundle.module.url(forResource: "openings", withExtension: "tsv"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        for line in text.split(separator: "\n").dropFirst() {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard f.count == 3 else { continue }
            let sans = f[2].split(separator: " ").map(String.init).filter { !$0.hasSuffix(".") }
            let o = Opening(eco: String(f[0]), name: String(f[1]), sans: sans)
            all.append(o)
            byLine[sans.joined(separator: " ")] = o
        }
    }

    /// The opening of the longest known prefix of the game.
    public func name(for sans: [String]) -> Opening? {
        var n = sans.count
        while n > 0 {
            if let o = byLine[sans.prefix(n).joined(separator: " ")] { return o }
            n -= 1
        }
        return nil
    }

    /// Next moves (SAN) that the book's named lines continue with after `sans`.
    public func continuations(after sans: [String]) -> [String] {
        all.compactMap { o in o.sans.count > sans.count && Array(o.sans.prefix(sans.count)) == sans ? o.sans[sans.count] : nil }
    }
}
