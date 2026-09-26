import AppKit

enum FontDetection {
    static let nerdFontFamilies: [String] = NSFontManager.shared.availableFontFamilies.filter { name in
        let n = name.lowercased()
        return n.contains("nerd font") || n.hasSuffix(" nf") || n.contains(" nfm") || n.contains("powerline")
    }.sorted()

    static func iTermFontName() -> String? {
        guard let profiles = UserDefaults(suiteName: "com.googlecode.iterm2")?.array(forKey: "New Bookmarks") as? [[String: Any]] else {
            return nil
        }
        let ordered = profiles.sorted { a, _ in (a["Default Bookmark"] as? String) == "Yes" }
        for profile in ordered {
            guard let spec = profile["Normal Font"] as? String else { continue }
            let parts = spec.split(separator: " ")
            let name = parts.count > 1 ? parts.dropLast().joined(separator: " ") : spec   // iTerm2 stores "Name-Style 12"
            if NSFont(name: name, size: 12) != nil { return name }
        }
        return nil
    }

    static func preferredFontName() -> String {
        if let name = iTermFontName() { return name }
        if let family = nerdFontFamilies.first { return family }
        return ""
    }
}
