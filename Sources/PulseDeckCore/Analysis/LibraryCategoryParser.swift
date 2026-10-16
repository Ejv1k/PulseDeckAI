import Foundation

/// Parses a category from a library-relative crate path using existing numbered crate naming.
public enum LibraryCategoryParser: Sendable {
    public static func category(for trackURL: URL, libraryRoot: URL) -> String? {
        let root = libraryRoot.standardizedFileURL.resolvingSymlinksInPath()
        let track = trackURL.standardizedFileURL.resolvingSymlinksInPath()
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard track.path.hasPrefix(prefix) else { return nil }
        let parts = track.path.dropFirst(prefix.count).split(separator: "/")
        guard let folder = parts.first, !folder.isEmpty else { return nil }
        let tokens = folder.split(separator: "_", omittingEmptySubsequences: true)
        guard !tokens.isEmpty else { return nil }
        let categoryTokens = Int(tokens[0]) == nil ? tokens[...] : tokens.dropFirst()
        guard !categoryTokens.isEmpty else { return nil }
        return categoryTokens.map(String.init).joined(separator: " ")
    }
}
