import Foundation

/// Searching the "Recent" list.
public enum RecentFiles {
    /// Lower case, without accents, and Vietnamese đ/Đ as d, so "dem" finds "Đêm" and "bai giang" finds "Bài giảng".
    public static func fold(_ s: String) -> String {
        s.replacingOccurrences(of: "đ", with: "d").replacingOccurrences(of: "Đ", with: "d")
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// The files whose name contains every word of `query` (in any order). Only when no file name matches, the folder a file is in
    /// counts too, so a short word such as "2" is not swallowed by some folder's path. An empty query keeps everything, in the same order.
    public static func search(_ urls: [URL], query: String) -> [URL] {
        let words = fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return urls }
        let byName = urls.filter { u in let n = fold(u.lastPathComponent); return words.allSatisfy { n.contains($0) } }
        if !byName.isEmpty { return byName }
        return urls.filter { u in
            let hay = fold(u.lastPathComponent) + "\n" + fold(u.deletingLastPathComponent().path)
            return words.allSatisfy { hay.contains($0) }
        }
    }
}
