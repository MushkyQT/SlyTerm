import Foundation

enum LookupText {
    static func clean(_ line: String) -> String {
        var t = line
        for (pattern, replacement) in genericPatterns {
            t = t.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func clean(_ line: String, for game: LookupGame?) -> String {
        var t = clean(line)
        for regex in regexes(game?.effectiveStripPatterns ?? [], kind: "strip") {
            t = regex.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: " ")
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isTooltipLine(_ line: String, for game: LookupGame?) -> Bool {
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(t.startIndex..., in: t)
        return regexes(game?.effectiveTooltipPatterns ?? [], kind: "tooltip line").contains { $0.firstMatch(in: t, range: range) != nil }
    }

    // Order matters: the level goes before the stack count, or "Niv. 50" reads as a count.
    private static let genericPatterns: [(String, String)] = [
        ("\\(?\\b\\d+\\s*/\\s*\\d+\\)?", " "),
        ("(?i)\\b(?:niveau|niv|level|lvl|lv)\\.?\\s*\\d+", " "),
        ("^\\s*\\[\\d+\\+?\\]\\s*", " "),
        ("\\s*\\(\\d+\\)\\s*$", " "),
        ("(?i)\\s*\\bx\\s*\\d[\\d,]*\\s*$", " "),
        ("(?i)^\\s*\\d[\\d,]*\\s*x\\s+", " "),
        ("^[\\s•\\-–—*!?]+", ""),
    ]

    private static let regexLock = NSLock()
    private static var compiled: [String: NSRegularExpression?] = [:]

    private static func regexes(_ patterns: [String], kind: String) -> [NSRegularExpression] {
        regexLock.withLock {
            patterns.compactMap { pattern in
                if let known = compiled[pattern] { return known }
                let regex = try? NSRegularExpression(pattern: pattern)
                if regex == nil { Settings.log("lookup: ignoring invalid \(kind) pattern \"\(pattern)\"") }
                compiled[pattern] = regex
                return regex
            }
        }
    }

    static func normalize(_ text: String) -> String {
        var t = text.lowercased()
            .replacingOccurrences(of: "œ", with: "oe")
            .replacingOccurrences(of: "æ", with: "ae")
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "fr_FR"))
        t = t.replacingOccurrences(of: "[’'`´ʼ]", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespaces)
    }

    static func score(line: String, name: String) -> Double {
        let a = Array(line.utf8), b = Array(name.utf8)
        var s = 1 - Double(levenshtein(a, b)) / Double(max(a.count, b.count, 1))
        let paddedLine = " " + line + " ", paddedName = " " + name + " "
        if name.count >= 6, line.count > name.count, paddedLine.contains(paddedName) {
            s = max(s, 0.9 + 0.1 * Double(name.count) / Double(line.count))
        } else if line.count >= 8, name.count > line.count, paddedName.contains(paddedLine) {
            s = max(s, 0.75)
        }
        return s
    }

    static func levenshtein(_ a: [UInt8], _ b: [UInt8]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}

final class LookupIndex {
    struct Entry {
        let name: String
        let norm: String
        let url: URL
    }
    struct Match {
        let entry: Entry
        let score: Double
    }

    // Sources on one host share this index, so this is whichever asked first: read only
    // `kind` and `indexURL` from it.
    let source: LookupSource
    let cacheURL: URL

    static let maxEntries = 100_000

    static let firstBuildWait: TimeInterval = 3

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var postings: [String: [Int]] = [:]
    private var built: Date?

    private let gate = NSCondition()
    private var refreshing = false

    init(source: LookupSource) {
        self.source = source
        cacheURL = LookupCache.url(for: source)
    }

    var count: Int { lock.withLock { entries.count } }
    var isEmpty: Bool { count == 0 }
    var builtAt: Date? { lock.withLock { built } }
    var age: TimeInterval? { builtAt.map { Date().timeIntervalSince($0) } }

    func prepare(force: Bool = false) {
        if isEmpty { loadCache() }
        if force || isEmpty || (age ?? .greatestFiniteMagnitude) > LookupCache.maxAge { refreshOnce(waiting: nil) }
    }

    func ensureLoaded(timeout: TimeInterval = firstBuildWait) {
        guard isEmpty else { return }
        loadCache()
        guard isEmpty else { return }
        refreshOnce(waiting: timeout)
    }

    private func refreshOnce(waiting timeout: TimeInterval?) {
        gate.lock()
        if !refreshing {
            refreshing = true
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                refresh()
                gate.lock()
                refreshing = false
                gate.broadcast()
                gate.unlock()
            }
        }
        if let timeout {
            let deadline = Date().addingTimeInterval(timeout)
            while refreshing, gate.wait(until: deadline) {}
        } else {
            while refreshing { gate.wait() }
        }
        gate.unlock()
    }

    private struct CacheFile: Codable {
        struct Item: Codable {
            let n: String
            let u: String
        }
        let builtAt: TimeInterval
        let entries: [Item]
    }

    @discardableResult
    private func loadCache() -> Int {
        guard let data = try? Data(contentsOf: cacheURL),
              let file = try? JSONDecoder().decode(CacheFile.self, from: data) else { return 0 }
        let loaded = file.entries.compactMap { item -> Entry? in
            guard let url = URL(string: item.u) else { return nil }
            return Entry(name: item.n, norm: LookupText.normalize(item.n), url: url)
        }
        install(loaded, builtAt: Date(timeIntervalSince1970: file.builtAt))
        Settings.log("lookup: \(source.host) index loaded from cache, \(loaded.count) titles")
        return loaded.count
    }

    private func writeCache(_ list: [Entry], builtAt: Date) {
        let file = CacheFile(builtAt: builtAt.timeIntervalSince1970,
                             entries: list.map { CacheFile.Item(n: $0.name, u: $0.url.absoluteString) })
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? data.write(to: cacheURL, options: .atomic)
        try? FileManager.default.removeItem(at: LookupCache.legacyFile)
    }

    @discardableResult
    func refresh() -> Int {
        guard let indexURL = source.indexURL else { return 0 }
        let started = Date()
        let crawl: (entries: [Entry], complete: Bool)
        switch source.kind {
        case .mediaWiki: crawl = Self.mediaWikiEntries(api: indexURL)
        case .weebly: crawl = Self.sitemapEntries(indexURL, weebly: true)
        case .website: crawl = Self.sitemapEntries(indexURL, weebly: false)
        case .wowhead, .dofusDB: crawl = ([], true)
        }
        let list = crawl.entries
        let installed = count
        // A half-finished crawl and a stub sitemap both look like a short list; neither may
        // replace a working index and be stamped fresh for a week.
        guard !list.isEmpty, crawl.complete || list.count >= installed,
              list.count >= min(100, max(1, installed)) else {
            Settings.log("lookup: \(source.host) index refresh incomplete, \(list.count) titles, keeping \(installed)")
            return 0
        }
        let now = Date()
        install(list, builtAt: now)
        writeCache(list, builtAt: now)
        Settings.log("lookup: \(source.host) index refreshed, \(list.count) titles in \(Int(now.timeIntervalSince(started) * 1000)) ms")
        return list.count
    }

    private func install(_ list: [Entry], builtAt: Date) {
        var index: [String: [Int]] = [:]
        for (i, entry) in list.enumerated() {
            for token in entry.norm.split(separator: " ") where token.count >= 3 {
                index[String(token), default: []].append(i)
            }
        }
        lock.withLock {
            entries = list
            postings = index
            built = builtAt
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Settings.didChange, object: "lookupIndex")
        }
    }

    func bestMatch(for line: String) -> Match? { matches(for: line, limit: 1).first }

    func matches(for line: String, limit: Int) -> [Match] {
        let cleaned = LookupText.clean(line)
        // Slugs spell an apostrophe either glued or as a separator ("dun" or "d-un").
        let spaced = cleaned.replacingOccurrences(of: "[’'`´ʼ]", with: " ", options: .regularExpression)
        let variants = Set([LookupText.normalize(cleaned), LookupText.normalize(spaced)]).filter { $0.count >= 3 }
        guard !variants.isEmpty else { return [] }
        return lock.withLock {
            var best: [Int: Double] = [:]
            for v in variants {
                var candidates = Set<Int>()
                for token in v.split(separator: " ") where token.count >= 3 {
                    postings[String(token)]?.forEach { candidates.insert($0) }
                }
                if candidates.isEmpty, entries.count <= 20_000 {
                    for i in entries.indices where abs(entries[i].norm.count - v.count) <= max(3, v.count / 3) { candidates.insert(i) }
                }
                for i in candidates {
                    let s = LookupText.score(line: v, name: entries[i].norm)
                    if s > best[i, default: 0] { best[i] = s }
                }
            }
            return best.sorted { $0.value > $1.value }.prefix(limit).map { Match(entry: entries[$0.key], score: $0.value) }
        }
    }

    static func sitemapEntries(_ url: URL, weebly: Bool) -> (entries: [Entry], complete: Bool) {
        var pages: [URL] = []
        var followed = 0
        let complete = follow(url, depth: 0, followed: &followed, into: &pages)
        var list: [Entry] = []
        var seen = Set<String>()
        for page in pages {
            let slug = pageSlug(of: page)
            guard !slug.isEmpty else { continue }
            if weebly, skippedWeeblySlugs.contains(slug) { continue }
            let name = weebly ? weeblyName(fromSlug: slug) : websiteName(fromSlug: slug)
            let norm = LookupText.normalize(name)
            guard norm.count >= 4, norm.contains(where: \.isLetter), seen.insert(page.absoluteString).inserted else { continue }
            list.append(Entry(name: name, norm: norm, url: page))
            if list.count >= maxEntries { break }
        }
        return (list, complete)
    }

    private static func follow(_ url: URL, depth: Int, followed: inout Int, into pages: inout [URL]) -> Bool {
        guard let data = LookupHTTP.fetch(url), let xml = String(data: data, encoding: .utf8) else { return false }
        var complete = true
        for location in locations(inSitemap: xml) {
            let path = location.path.lowercased()
            if path.hasSuffix(".xml.gz") {
                Settings.log("lookup: skipping gzipped sitemap \(location.lastPathComponent)")
                complete = false
                continue
            }
            guard path.hasSuffix(".xml") else { pages.append(location); continue }
            guard depth < 2, followed < 50 else { complete = false; continue }
            followed += 1
            if !follow(location, depth: depth + 1, followed: &followed, into: &pages) { complete = false }
        }
        return complete
    }

    private static func pageSlug(of page: URL) -> String {
        let slug = page.lastPathComponent
        guard let dot = slug.lastIndex(of: "."), dot != slug.startIndex else { return slug }
        let ext = slug[slug.index(after: dot)...].lowercased()
        guard ext.count <= 5, !ext.isEmpty, ext.allSatisfy(\.isLetter) else { return slug }
        return String(slug[slug.startIndex..<dot])
    }

    private static func locations(inSitemap xml: String) -> [URL] {
        let pattern = try! NSRegularExpression(pattern: "<loc>\\s*(https?://[^<\\s]+)\\s*</loc>")
        return pattern.matches(in: xml, range: NSRange(xml.startIndex..., in: xml)).compactMap { m in
            guard let r = Range(m.range(at: 1), in: xml) else { return nil }
            return URL(string: String(xml[r]))
        }
    }

    static let skippedWeeblySlugs: Set<String> = ["index", "quecirctes", "contact", "envoyer-une-quete", "donjons"]

    // Weebly slugs spell accents as bare entity names: "agrave-la-recherche" is "à la recherche".
    static func weeblyName(fromSlug slug: String) -> String {
        var s = slug
        for (entity, letter) in entities { s = s.replacingOccurrences(of: entity, with: letter) }
        return capitalised(s.split(separator: "-").map(String.init))
    }

    static func websiteName(fromSlug slug: String) -> String {
        let decoded = slug.removingPercentEncoding ?? slug
        let words = decoded.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " })
            .map(String.init)
            .filter { !$0.isEmpty && !$0.allSatisfy(\.isNumber) }
        return capitalised(words)
    }

    private static func capitalised(_ words: [String]) -> String {
        words.enumerated().map { i, w in
            i == 0 || w.count > 3 ? w.prefix(1).uppercased() + w.dropFirst() : w
        }.joined(separator: " ")
    }

    private static let entities: [(String, String)] = [
        ("agrave", "a"), ("aacute", "a"), ("acirc", "a"), ("auml", "a"),
        ("eacute", "e"), ("egrave", "e"), ("ecirc", "e"), ("euml", "e"),
        ("iacute", "i"), ("igrave", "i"), ("icirc", "i"), ("iuml", "i"),
        ("oacute", "o"), ("ograve", "o"), ("ocirc", "o"), ("ouml", "o"), ("oelig", "oe"),
        ("uacute", "u"), ("ugrave", "u"), ("ucirc", "u"), ("uuml", "u"),
        ("ccedil", "c"), ("ntilde", "n"), ("rsquo", ""), ("lsquo", ""), ("hellip", ""),
    ]

    static let entityNames: [String] = entities.map(\.0)

    // Dedupe by URL, not normalised name: "Antipoison (-)" and "Antipoison (+)" normalise alike.
    static func mediaWikiEntries(api: URL) -> (entries: [Entry], complete: Bool) {
        guard let site = MediaWikiSite(api: api) else { return ([], false) }
        var list: [Entry] = []
        var seen = Set<String>()
        var next: String?
        var pages = 0
        var complete = true
        repeat {
            var items = [URLQueryItem(name: "action", value: "query"),
                         URLQueryItem(name: "list", value: "allpages"),
                         URLQueryItem(name: "apnamespace", value: "0"),
                         URLQueryItem(name: "apfilterredir", value: "nonredirects"),
                         URLQueryItem(name: "aplimit", value: "500"),
                         URLQueryItem(name: "format", value: "json")]
            if let next { items.append(URLQueryItem(name: "apcontinue", value: next)) }
            guard let url = LookupHTTP.url(api, items),
                  let data = LookupHTTP.fetch(url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { complete = false; break }
            let titles = ((json["query"] as? [String: Any])?["allpages"] as? [[String: Any]] ?? [])
                .compactMap { $0["title"] as? String }
            for title in titles {
                let norm = LookupText.normalize(title)
                guard norm.count >= 2, norm.contains(where: \.isLetter),
                      let url = site.articleURL(for: title), seen.insert(url.absoluteString).inserted else { continue }
                list.append(Entry(name: title, norm: norm, url: url))
            }
            next = (json["continue"] as? [String: Any])?["apcontinue"] as? String
            pages += 1
        } while next != nil && list.count < maxEntries && pages < 220
        return (Array(list.prefix(maxEntries)), complete)
    }
}

struct MediaWikiSite {
    let server: String
    let articlePath: String
    let articles: Int?
    let name: String?

    init?(api: URL) {
        guard let url = LookupHTTP.url(api, [URLQueryItem(name: "action", value: "query"),
                                             URLQueryItem(name: "meta", value: "siteinfo"),
                                             URLQueryItem(name: "siprop", value: "statistics|general"),
                                             URLQueryItem(name: "format", value: "json")]),
              let data = LookupHTTP.fetch(url) else { return nil }
        self.init(siteinfo: data, api: api)
    }

    init?(siteinfo data: Data, api: URL) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let query = json["query"] as? [String: Any],
              let general = query["general"] as? [String: Any],
              let path = general["articlepath"] as? String else { return nil }
        var server = (general["server"] as? String) ?? (general["base"] as? String) ?? ""
        if server.hasPrefix("//") { server = (api.scheme ?? "https") + ":" + server }
        if server.isEmpty { server = api.scheme.map { "\($0)://\(api.host ?? "")" } ?? "" }
        self.server = server.hasSuffix("/") ? String(server.dropLast()) : server
        articlePath = path
        articles = (query["statistics"] as? [String: Any])?["articles"] as? Int
        name = general["sitename"] as? String
    }

    func articleURL(for title: String) -> URL? {
        let underscored = title.replacingOccurrences(of: " ", with: "_")
        let encoded = underscored.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? underscored
        return URL(string: server + articlePath.replacingOccurrences(of: "$1", with: encoded))
    }
}

enum LookupIndices {
    private static let lock = NSLock()
    private static var byFile: [String: LookupIndex] = [:]

    static func index(for source: LookupSource) -> LookupIndex? {
        guard source.kind.canIndex, source.indexURL != nil else { return nil }
        let file = LookupCache.url(for: source).path
        return lock.withLock {
            if let existing = byFile[file], existing.source.indexURL == source.indexURL,
               existing.source.kind == source.kind { return existing }
            let index = LookupIndex(source: source)
            byFile[file] = index
            return index
        }
    }

    static func indexed(_ game: LookupGame) -> [(source: LookupSource, index: LookupIndex)] {
        game.sources.compactMap { source in index(for: source).map { (source, $0) } }
    }
}
