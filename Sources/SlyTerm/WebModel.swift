import AppKit

// Web tabs are GuideTabs: a page the lookup opened or one typed into an address field, docked in
// the main window or floating in a FloatingWeb. This file holds what GuideTab, FloatingWeb, the
// strip and OverlayController share.

// Merged over every frame of the page; it comes from the page's own script, so it is untrusted.
struct WebMediaState: Equatable {
    var isPlaying = false
    var hasVideo = false
    var aspect: CGFloat?
    var isFilled = false

    static let none = WebMediaState()
}

enum WebTabPlace: Equatable { case docked, floating }

protocol WebTabHost: AnyObject {
    var isGhost: Bool { get }
    @discardableResult
    func openWebTab(_ url: URL?, select: Bool, focusAddress: Bool) -> GuideTab
    func float(_ tab: GuideTab)
    func dock(_ tab: GuideTab)
    func closeWebTab(_ tab: GuideTab)
    func webTabDidChange(_ tab: GuideTab)
}

struct TabStripWebItem: Equatable {
    var title: String
    var icon: NSImage?
    var symbol: String
    var isSelected: Bool
    var isFloating: Bool
    var isPlaying: Bool
}

enum WebSites {
    static let defaultSearchURL = "https://duckduckgo.com/?q={query}"

    // Their players break under the reader's styling, and YouTube walls off playback when its ad
    // requests are blocked, so these get neither.
    static let streamingHosts = [
        "youtube.com", "youtu.be", "youtube-nocookie.com", "netflix.com", "twitch.tv", "kick.com",
        "primevideo.com", "disneyplus.com", "max.com", "hbomax.com", "hulu.com", "paramountplus.com",
        "peacocktv.com", "crunchyroll.com", "tv.apple.com", "music.apple.com", "spotify.com",
        "deezer.com", "soundcloud.com", "vimeo.com", "dailymotion.com", "plex.tv", "canalplus.com",
        "france.tv", "arte.tv", "molotov.tv",
    ]

    static func isStreaming(_ host: String) -> Bool {
        let host = host.lowercased()
        return streamingHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    // Services offer FairPlay only to a client that presents as Safari, and WKWebView's own user
    // agent stops right before the `Version/… Safari/…` they look for.
    static let safariUserAgentSuffix: String = {
        let plist = URL(fileURLWithPath: "/Applications/Safari.app/Contents/Info.plist")
        let installed = (NSDictionary(contentsOf: plist)?["CFBundleShortVersionString"] as? String)?
            .split(separator: ".").prefix(2).joined(separator: ".")
        let version = installed.flatMap { $0.isEmpty ? nil : $0 } ?? "18.0"
        return "Version/\(version) Safari/605.1.15"
    }()

    // What an address field's text opens: a web address as typed, a bare host as https (http for
    // localhost and IPv4 addresses), anything else as a search. Only http and https ever come out.
    static func address(for typed: String, searchURL: String) -> URL? {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https", url.host?.isEmpty == false {
            return url
        }
        if text.rangeOfCharacter(from: .whitespacesAndNewlines) == nil, let host = hostPart(of: text) {
            let local = host == "localhost" || isIPv4(host)
            if local || looksLikeDomain(host), let url = URL(string: (local ? "http://" : "https://") + text),
               url.host?.lowercased() == host {
                return url
            }
        }
        return search(text, with: searchURL) ?? search(text, with: defaultSearchURL)
    }

    private static func search(_ text: String, with template: String) -> URL? {
        guard template.contains("{query}") else { return nil }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let query = text.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: template.replacingOccurrences(of: "{query}", with: query)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    private static func hostPart(of text: String) -> String? {
        let end = text.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? text.endIndex
        var host = String(text[..<end])
        if let colon = host.lastIndex(of: ":") {
            guard host[host.index(after: colon)...].allSatisfy(\.isNumber) else { return nil }
            host = String(host[..<colon])
        }
        return host.isEmpty ? nil : host.lowercased()
    }

    private static func looksLikeDomain(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, let tld = labels.last, tld.count >= 2, tld.allSatisfy(\.isLetter) else { return false }
        return labels.allSatisfy { label in
            !label.isEmpty && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }
    }

    private static func isIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            !part.isEmpty && part.count <= 3 && part.allSatisfy(\.isNumber) && (Int(part) ?? 256) <= 255
        }
    }
}
