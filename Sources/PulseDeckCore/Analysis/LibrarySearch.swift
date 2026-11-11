import Foundation

/// Finds tracks across every crate, so a guest request is one search away.
public enum LibrarySearch {
    /// Library-relative paths (`crate/file`) whose file name or crate name contains every word of `query`,
    /// ignoring case and diacritics. Titles that start with the query come first; otherwise library order is kept.
    public static func search(_ query: String, in crates: [LibraryCrateInfo], limit: Int = 200) -> [String] {
        let words = fold(query.replacingOccurrences(of: "_", with: " ")).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        let needle = words.joined(separator: " ")
        var prefixHits: [String] = [], otherHits: [String] = []
        for crate in crates where crate.isReadable {
            let crateName = fold(crate.displayName)
            for file in crate.audioFiles {
                let title = fold((file as NSString).deletingPathExtension.replacingOccurrences(of: "_", with: " "))
                let haystack = title + " " + crateName
                guard words.allSatisfy(haystack.contains) else { continue }
                let path = "\(crate.folderName)/\(file)"
                if title.hasPrefix(needle) { prefixHits.append(path) } else { otherHits.append(path) }
            }
        }
        return Array((prefixHits + otherHits).prefix(limit))
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
