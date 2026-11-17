import Foundation

extension FileManager {
    /// Sidra's Application Support folder; a bundle-id folder on the Mac, where it is shared.
    /// ponytail: a copy of SidraDesign's `sidraSupport`, since SidraSSH does not depend on SidraDesign.
    var sshSupport: URL? {
        guard var dir = try? url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return nil }
        #if os(macOS)
        dir.append(path: Bundle.main.bundleIdentifier ?? "nl.sadiq.sidra.mac", directoryHint: .isDirectory)
        try? createDirectory(at: dir, withIntermediateDirectories: true)
        #endif
        return dir
    }
}
