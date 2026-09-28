import Foundation

enum LookupHTTP {
    static let userAgent = "Mozilla/5.0 (Macintosh) SlyTerm"
    // Wowhead's suggestions endpoint answers nothing unless the User-Agent looks like a browser.
    static let browserUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
    static let timeout: TimeInterval = 6
    static let maxBytes = 32 * 1024 * 1024

    static func request(_ url: URL, userAgent: String = userAgent) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    private static func accepted(_ data: Data?, _ response: URLResponse?, from url: URL) -> Data? {
        if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
            Settings.log("lookup: \(url.host ?? "request") answered \(status)")
            return nil
        }
        guard let data else { return nil }
        guard data.count <= maxBytes else {
            Settings.log("lookup: \(url.host ?? "request") answered \(data.count / 1024) KB, more than a lookup reads")
            return nil
        }
        return data
    }

    static func get(_ url: URL, userAgent: String = userAgent) async -> Data? {
        do {
            let (data, response) = try await URLSession.shared.data(for: request(url, userAgent: userAgent))
            return accepted(data, response, from: url)
        } catch {
            Settings.log("lookup: \(url.host ?? "request") failed: \(error.localizedDescription)")
            return nil
        }
    }

    // After a timeout the completion handler may still be running, hence the lock on `result`.
    static func fetch(_ url: URL, userAgent: String = userAgent) -> Data? {
        let lock = NSLock()
        var result: Data?
        let semaphore = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request(url, userAgent: userAgent)) { data, response, error in
            if let error { Settings.log("lookup: \(url.host ?? "request") failed: \(error.localizedDescription)") }
            let answer = accepted(data, response, from: url)
            lock.withLock { result = answer }
            semaphore.signal()
        }
        task.resume()
        guard semaphore.wait(timeout: .now() + timeout + 1) == .success else {
            task.cancel()
            Settings.log("lookup: \(url.host ?? "request") timed out")
            return nil
        }
        return lock.withLock { result }
    }

    static func url(_ base: URL, _ items: [URLQueryItem]) -> URL? {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = (components.queryItems ?? []) + items
        return components.url
    }

    // Keeps `home`'s path prefix: Wowhead's `/classic` endpoints differ from the origin's.
    // Built by hand because relative resolution depends on a trailing slash in `home`.
    static func endpoint(_ path: String, on home: URL) -> URL? {
        guard var components = URLComponents(url: home, resolvingAgainstBaseURL: false) else { return nil }
        var base = components.path
        while base.hasSuffix("/") { base.removeLast() }
        components.path = base + (path.hasPrefix("/") ? path : "/" + path)
        components.query = nil
        components.fragment = nil
        return components.url
    }
}

struct LookupHit {
    let name: String
    let url: URL
}

enum LookupResolver {
    static let acceptance = 0.72

    typealias Answer = (source: LookupSource, hit: LookupHit)

    static func hit(for text: String, source: LookupSource) async -> LookupHit? {
        switch source.kind {
        case .mediaWiki: return await mediaWiki(text, source: source)
        case .wowhead: return await wowhead(text, source: source)
        case .weebly: return await weebly(text, source: source)
        case .dofusDB: return await dofusDB(text, source: source)
        case .website: return nil
        }
    }

    static func hit(for text: String, game: LookupGame,
                    confirm: @escaping @Sendable (LookupSource, LookupHit) -> Bool = { _, _ in true }) async -> Answer? {
        let sources = game.resolvingSources
        guard !sources.isEmpty else { return nil }
        return await withTaskGroup(of: Event.self) { group in
            for (n, source) in sources.enumerated() {
                group.addTask {
                    guard let hit = await hit(for: text, source: source), confirm(source, hit) else { return .answer(n, nil) }
                    return .answer(n, hit)
                }
            }
            var answers: [Int: LookupHit?] = [:]
            var waiting = false
            func chosen() -> Answer? { choose(sources.indices.map { answers[$0] ?? nil }, of: sources, for: text) }
            for await event in group {
                guard case .answer(let n, let hit) = event else {
                    // `try? Task.sleep` also ends on cancellation: check before taking it as grace.
                    guard !Task.isCancelled else { return nil }
                    let late = sources.indices.filter { answers[$0] == nil }.map { sources[$0].name }
                    Settings.log("lookup: \(late.joined(separator: ", ")) did not answer \"\(text)\" within \(grace) s of the first answer")
                    group.cancelAll()
                    return chosen()
                }
                answers[n] = .some(hit)
                for m in sources.indices {
                    guard let answer = answers[m] else { break }
                    guard let hit = answer, namesText(hit, text) else { continue }
                    group.cancelAll()
                    return (sources[m], hit)
                }
                if answers.count == sources.count {
                    group.cancelAll()
                    guard !Task.isCancelled else { return nil }
                    return chosen()
                }
                if hit != nil, !waiting {
                    waiting = true
                    group.addTask {
                        try? await Task.sleep(for: .seconds(grace))
                        return .graceOver
                    }
                }
            }
            return nil
        }
    }

    static let grace: TimeInterval = 1

    private enum Event {
        case answer(Int, LookupHit?)
        case graceOver
    }

    static func choose(_ answers: [LookupHit?], of sources: [LookupSource], for text: String) -> Answer? {
        let given = zip(sources, answers).compactMap { source, hit in hit.map { (source: source, hit: $0) } }
        return given.first { namesText($0.hit, text) } ?? given.first
    }

    private static func namesText(_ hit: LookupHit, _ text: String) -> Bool {
        Lookup.sameName(LookupText.normalize(LookupText.clean(text)), LookupText.normalize(hit.name)) >= Lookup.nearbyThreshold
    }

    private static func mediaWiki(_ text: String, source: LookupSource) async -> LookupHit? {
        let cleaned = LookupText.clean(text)
        guard let api = source.indexURL ?? LookupHTTP.endpoint("/api.php", on: source.home),
              let url = LookupHTTP.url(api, [URLQueryItem(name: "action", value: "opensearch"),
                                             URLQueryItem(name: "search", value: cleaned),
                                             URLQueryItem(name: "limit", value: "5"),
                                             URLQueryItem(name: "format", value: "json")]),
              let data = await LookupHTTP.get(url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any], json.count >= 4,
              let names = json[1] as? [String], let pages = json[3] as? [String] else { return nil }
        let wanted = LookupText.normalize(cleaned)
        for (i, name) in names.enumerated() where i < pages.count {
            let score = LookupText.score(line: wanted, name: LookupText.normalize(name))
            Settings.log("lookup: opensearch \"\(cleaned)\" -> \(name) \(String(format: "%.3f", score))")
            guard score >= acceptance, let page = URL(string: pages[i]) else { continue }
            return LookupHit(name: name, url: page)
        }
        return nil
    }

    private static func wowhead(_ text: String, source: LookupSource) async -> LookupHit? {
        let cleaned = LookupText.clean(text)
        guard let endpoint = LookupHTTP.endpoint("/search/suggestions-template", on: source.home),
              let url = LookupHTTP.url(endpoint, [URLQueryItem(name: "q", value: cleaned)]),
              let data = await LookupHTTP.get(url, userAgent: LookupHTTP.browserUserAgent),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return nil }
        let wanted = LookupText.normalize(cleaned)
        var candidates: [(hit: LookupHit, score: Double, rank: Int, order: Int)] = []
        for (order, result) in results.enumerated() {
            // Wowhead page paths are one-word types; "Battle Pet" has no `/type=id` page.
            guard let name = result["name"] as? String,
                  let typeName = (result["typeName"] as? String)?.lowercased(),
                  !typeName.isEmpty, typeName.allSatisfy(\.isLetter),
                  let id = result["id"] as? Int,
                  let page = LookupHTTP.endpoint("/\(typeName)=\(id)", on: source.home) else { continue }
            let score = LookupText.score(line: wanted, name: LookupText.normalize(name))
            guard score >= acceptance else { continue }
            let rank = types.firstIndex(of: typeName) ?? types.count
            candidates.append((LookupHit(name: name, url: page), score, rank, order))
        }
        guard let best = candidates.map(\.score).max() else { return nil }
        let winner = candidates.filter { $0.score >= best - 0.001 }
            .min { ($0.rank, $0.order) < ($1.rank, $1.order) }
        if let winner {
            Settings.log("lookup: wowhead \"\(cleaned)\" -> \(winner.hit.name) \(String(format: "%.3f", winner.score)) \(winner.hit.url.lastPathComponent)")
        }
        return winner?.hit
    }

    private static let types = ["quest", "item", "npc", "zone", "achievement", "spell"]

    private static func weebly(_ text: String, source: LookupSource) async -> LookupHit? {
        let cleaned = LookupText.clean(text)
        guard looksLikeTitle(cleaned) else { return nil }
        let wanted = significant(LookupText.normalize(cleaned))
        guard let search = LookupHTTP.endpoint("/apps/search", on: source.home),
              let url = LookupHTTP.url(search, [URLQueryItem(name: "q", value: cleaned)]),
              let data = await LookupHTTP.get(url),
              let html = String(data: data, encoding: .utf8) else { return nil }
        guard let result = try? NSRegularExpression(pattern: "<li>\\s*<a href=\"(/[^\"]+\\.html)\">\\s*<h3>\\s*([^<]+?)\\s*</h3>\\s*</a>(.*?)</li>",
                                                    options: .dotMatchesLineSeparators),
              let m = result.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let pr = Range(m.range(at: 1), in: html), let nr = Range(m.range(at: 2), in: html),
              let sr = Range(m.range(at: 3), in: html) else { return nil }
        let path = String(html[pr])
        let slug = path.hasSuffix(".html") ? String(path.dropFirst().dropLast(5)) : String(path.dropFirst())
        if LookupIndex.skippedWeeblySlugs.contains(slug) { return nil }
        let title = decodeEntities(String(html[nr]))
        // Weebly's search ORs words and wraps the matched ones in <em> in the snippet.
        var highlighted = significant(LookupText.normalize(title))
        let block = String(html[sr])
        if let em = try? NSRegularExpression(pattern: "<em>([^<]+)</em>") {
            for e in em.matches(in: block, range: NSRange(block.startIndex..., in: block)) {
                if let r = Range(e.range(at: 1), in: block) { highlighted.formUnion(significant(LookupText.normalize(decodeEntities(String(block[r]))))) }
            }
        }
        let covered = wanted.intersection(highlighted)
        let inTitle = !wanted.intersection(significant(LookupText.normalize(title))).isEmpty
        Settings.log("lookup: search \"\(text)\" -> \(title): covered \(covered.sorted()) of \(wanted.sorted()), in title: \(inTitle)")
        let convincing = inTitle || (wanted.count >= 2 && Double(covered.count) / Double(wanted.count) >= 0.5)
        guard convincing, covered.contains(where: { $0.count >= 4 }),
              let hit = URL(string: path, relativeTo: source.home)?.absoluteURL else { return nil }
        return LookupHit(name: title, url: hit)
    }

    private static let stopwords: Set<String> = [
        "les", "des", "une", "pour", "dans", "sur", "avec", "par", "aux", "est", "qui", "que", "pas", "plus",
        "mes", "ses", "tes", "nos", "vos", "leur", "niv", "the", "and", "for", "with",
    ]

    static func looksLikeTitle(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count <= 60, t.split(separator: " ").count <= 8 else { return false }
        if t.range(of: "[.;!?…]$|[.;!?]\\s", options: .regularExpression) != nil { return false }
        return !significant(LookupText.normalize(LookupText.clean(t))).isEmpty
    }

    static func significant(_ normalized: String) -> Set<String> {
        Set(normalized.split(separator: " ").map(String.init)
            .filter { $0.count >= 3 && !stopwords.contains($0) && $0.contains(where: \.isLetter) })
    }

    static func decodeEntities(_ s: String) -> String {
        var out = s
        let named = ["&amp;": "&", "&quot;": "\"", "&apos;": "'", "&rsquo;": "’", "&nbsp;": " ",
                     "&eacute;": "é", "&egrave;": "è", "&ecirc;": "ê", "&euml;": "ë", "&agrave;": "à", "&acirc;": "â",
                     "&ocirc;": "ô", "&icirc;": "î", "&iuml;": "ï", "&ucirc;": "û", "&ugrave;": "ù", "&ccedil;": "ç", "&oelig;": "œ"]
        for (k, v) in named { out = out.replacingOccurrences(of: k, with: v) }
        if let re = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);") {
            let ns = out as NSString
            var result = ""
            var last = 0
            for m in re.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
                result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let hex = m.range(at: 1).length > 0
                if let code = UInt32(ns.substring(with: m.range(at: 2)), radix: hex ? 16 : 10), let scalar = Unicode.Scalar(code) {
                    result.unicodeScalars.append(scalar)
                }
                last = m.range.location + m.range.length
            }
            result += ns.substring(from: last)
            out = result
        }
        return out
    }

    // DofusDB's API (Feathers over Mongo) is queried by `$regex`: its full-text `$search`
    // answers 500 and an exact name misses OCR slips.
    private static func dofusDB(_ text: String, source: LookupSource) async -> LookupHit? {
        let cleaned = LookupText.clean(text)
        guard looksLikeTitle(cleaned) else { return nil }
        let wanted = LookupText.normalize(cleaned)
        switch await dofusDB(namePattern(cleaned), for: cleaned, wanted: wanted, source: source) {
        case .hit(let hit): return hit
        case .failed: return nil
        case .noMatch: break
        }
        guard !Task.isCancelled, let word = longestWord(of: cleaned), LookupText.normalize(word) != wanted else { return nil }
        guard case .hit(let hit) = await dofusDB(namePattern(word), for: cleaned, wanted: wanted, source: source) else { return nil }
        return hit
    }

    private enum DofusDBAnswer {
        case hit(LookupHit)
        case noMatch
        case failed
    }

    private static func dofusDB(_ pattern: String, for cleaned: String, wanted: String, source: LookupSource) async -> DofusDBAnswer {
        let language = dofusDBLanguage(of: source.home)
        let field = "name.\(language)"
        guard var components = URLComponents(url: dofusDBAPI.appendingPathComponent("items"), resolvingAgainstBaseURL: false)
        else { return .failed }
        // Encoded by hand: URLComponents leaves `+` unescaped and the server reads it as a space.
        let items = [("\(field)[$regex]", pattern), ("\(field)[$options]", "i"), ("$limit", "50"),
                     ("$select[]", "id"), ("$select[]", "name")]
        components.percentEncodedQuery = items.map { "\(queryEncoded($0))=\(queryEncoded($1))" }.joined(separator: "&")
        guard let url = components.url,
              let data = await LookupHTTP.get(url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["data"] as? [[String: Any]] else { return .failed }
        var best: (hit: LookupHit, score: Double)?
        for result in results {
            guard let id = result["id"] as? Int,
                  let name = (result["name"] as? [String: Any])?[language] as? String,
                  let page = LookupHTTP.endpoint("/database/object/\(id)", on: source.home) else { continue }
            let score = LookupText.score(line: wanted, name: LookupText.normalize(name))
            if score > best?.score ?? 0 { best = (LookupHit(name: name, url: page), score) }
        }
        Settings.log("lookup: dofusdb \"\(cleaned)\" /\(pattern)/ -> \(results.count) names, best "
                     + (best.map { "\($0.hit.name) \(String(format: "%.3f", $0.score)) \($0.hit.url.lastPathComponent)" } ?? "none"))
        guard let best, best.score >= acceptance else { return .noMatch }
        return .hit(best.hit)
    }

    private static let dofusDBAPI = URL(string: "https://api.dofusdb.fr")!

    static let dofusDBLanguages = ["fr", "en", "es", "de", "pt"]

    static func dofusDBLanguage(of url: URL) -> String {
        let first = url.pathComponents.dropFirst().first?.lowercased() ?? ""
        return dofusDBLanguages.contains(first) ? first : "fr"
    }

    // OCR drops accents and, in Dofus's font, confuses i, l, 1 and | ("Wabbit" reads "Wabblt").
    static func namePattern(_ text: String) -> String {
        let chars = Array(text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))
        func base(_ c: Character) -> String { String(c).folding(options: .diacriticInsensitive, locale: nil) }
        var out = ""
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace {
                while i < chars.count, chars[i].isWhitespace { i += 1 }
                out += "\\s+"
                continue
            }
            if c == "œ" || (base(c) == "o" && i + 1 < chars.count && base(chars[i + 1]) == "e") {
                out += "(?:[oòóôõö][eéèêë]|œ)"
                i += c == "œ" ? 1 : 2
                continue
            }
            if let letter = letterClasses[base(c)] {
                out += letter
            } else if "'’`´ʼ".contains(c) {
                out += "['’`´ʼ]"
            } else if "-‐‑–—".contains(c) {
                out += "[-‐‑–—]"
            } else if c.isASCII, !c.isLetter, !c.isNumber {
                out += "\\" + String(c)
            } else {
                out += String(c)
            }
            i += 1
        }
        return out
    }

    private static let letterClasses: [String: String] = [
        "a": "[aàáâãäå]", "e": "[eéèêë]", "o": "[oòóôõö]", "u": "[uùúûü]", "y": "[yýÿ]",
        "c": "[cç]", "n": "[nñ]",
        "i": "[iìíîïl1|]", "l": "[liìíîï1|]", "1": "[1il|]", "|": "[|il1]",
    ]

    private static func longestWord(of text: String) -> String? {
        text.split { !$0.isLetter && !$0.isNumber }.map(String.init)
            .filter { $0.filter(\.isLetter).count >= 4 }
            .max { $0.count < $1.count }
    }

    private static func queryEncoded(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}

enum LookupProbe {
    struct Result {
        var kind: LookupSource.Kind
        var home: URL
        var indexURL: URL?
        var pageCount: Int?
        var searchURL: String? = nil
    }

    static func detect(searchURL: URL) async -> Result {
        let origin = LookupSource.origin(of: searchURL.absoluteString) ?? searchURL
        for path in ["/api.php", "/w/api.php"] {
            guard let api = URL(string: path, relativeTo: origin)?.absoluteURL,
                  let url = LookupHTTP.url(api, [URLQueryItem(name: "action", value: "query"),
                                                 URLQueryItem(name: "meta", value: "siteinfo"),
                                                 URLQueryItem(name: "siprop", value: "statistics|general"),
                                                 URLQueryItem(name: "format", value: "json")]),
                  let data = await LookupHTTP.get(url),
                  let site = MediaWikiSite(siteinfo: data, api: api) else { continue }
            Settings.log("lookup: probe \(origin.host ?? "") is a MediaWiki at \(api.path), \(site.articles ?? 0) articles")
            // An articlepath with a query of its own (`/index.php?title=$1`) cannot take a second
            // one, so those go through index.php next to api.php.
            let folder = (api.path as NSString).deletingLastPathComponent
            let search = site.articlePath.contains("$1") && !site.articlePath.contains("?")
                ? site.server + site.articlePath.replacingOccurrences(of: "$1", with: "Special:Search?search={query}")
                : site.server + (folder == "/" ? "" : folder) + "/index.php?title=Special:Search&search={query}"
            return Result(kind: .mediaWiki, home: URL(string: site.server) ?? origin, indexURL: api,
                          pageCount: site.articles, searchURL: search)
        }
        if let host = origin.host?.lowercased(), host == "wowhead.com" || host.hasSuffix(".wowhead.com") {
            var prefix = (searchURL.path as NSString).deletingLastPathComponent
            while prefix.hasSuffix("/") { prefix.removeLast() }
            let home = prefix.isEmpty ? origin : (URL(string: prefix, relativeTo: origin)?.absoluteURL ?? origin)
            Settings.log("lookup: probe \(host) is Wowhead\(prefix.isEmpty ? "" : " at \(prefix)")")
            return Result(kind: .wowhead, home: home, indexURL: nil, pageCount: nil)
        }
        if let host = origin.host?.lowercased(),
           host == LookupPresets.dofusDBHost || host.hasSuffix("." + LookupPresets.dofusDBHost) {
            let language = LookupResolver.dofusDBLanguage(of: searchURL)
            let home = URL(string: "/" + language, relativeTo: origin)?.absoluteURL ?? origin
            Settings.log("lookup: probe \(host) is DofusDB, in \(language)")
            return Result(kind: .dofusDB, home: home, indexURL: nil, pageCount: nil)
        }
        if let sitemap = URL(string: "/sitemap.xml", relativeTo: origin)?.absoluteURL,
           let data = await LookupHTTP.get(sitemap),
           let xml = String(data: data, encoding: .utf8),
           xml.contains("<urlset") || xml.contains("<sitemapindex") {
            let count = xml.components(separatedBy: "<loc>").count - 1
            let kind: LookupSource.Kind = await isWeebly(sitemap: xml, searchURL: searchURL, origin: origin) ? .weebly : .website
            Settings.log("lookup: probe \(origin.host ?? "") is a \(kind.title) with \(count) addresses in its sitemap")
            return Result(kind: kind, home: origin, indexURL: sitemap, pageCount: count)
        }
        Settings.log("lookup: probe \(origin.host ?? "") has no index")
        return Result(kind: .website, home: origin, indexURL: nil, pageCount: nil)
    }

    private static func isWeebly(sitemap xml: String, searchURL: URL, origin: URL) async -> Bool {
        let slugs = xml.lowercased()
        guard LookupIndex.entityNames.contains(where: slugs.contains) else { return false }
        if searchURL.path.lowercased().contains("apps/search") || slugs.contains("weebly") { return true }
        guard let data = await LookupHTTP.get(origin),
              let html = String(data: data, encoding: .utf8) else { return false }
        return html.lowercased().contains("weebly")
    }
}
