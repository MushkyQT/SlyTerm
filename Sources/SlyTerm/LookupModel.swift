import Foundation

struct LookupGame: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var appBundleIDs: [String]
    var ocrLanguages: [String]
    var stripPatterns: [String]
    var tooltipPatterns: [String]
    var sources: [LookupSource]
    var preset: String?

    init(id: UUID = UUID(), name: String, appBundleIDs: [String] = [], ocrLanguages: [String] = [],
         stripPatterns: [String] = [], tooltipPatterns: [String] = [], sources: [LookupSource] = [],
         preset: String? = nil) {
        self.id = id
        self.name = name
        self.appBundleIDs = appBundleIDs
        self.ocrLanguages = ocrLanguages
        self.stripPatterns = stripPatterns
        self.tooltipPatterns = tooltipPatterns
        self.sources = sources
        self.preset = preset
    }

    // Lenient on purpose: imported files are often hand-written; only `name` is required.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        appBundleIDs = try c.decodeIfPresent([String].self, forKey: .appBundleIDs) ?? []
        ocrLanguages = try c.decodeIfPresent([String].self, forKey: .ocrLanguages) ?? []
        stripPatterns = try c.decodeIfPresent([String].self, forKey: .stripPatterns) ?? []
        tooltipPatterns = try c.decodeIfPresent([String].self, forKey: .tooltipPatterns) ?? []
        sources = try c.decodeIfPresent([LookupSource].self, forKey: .sources) ?? []
        preset = try c.decodeIfPresent(String.self, forKey: .preset)
    }

    func matches(bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        return appBundleIDs.contains { $0.caseInsensitiveCompare(bundleID) == .orderedSame }
    }

    var primarySource: LookupSource? { sources.first }

    var resolvingSources: [LookupSource] { sources.filter { $0.kind.canResolve } }

    var effectiveStripPatterns: [String] {
        Self.merged(madeFrom?.builtInStripPatterns ?? [], stripPatterns)
    }

    var effectiveTooltipPatterns: [String] {
        Self.merged(madeFrom?.builtInTooltipPatterns ?? [], tooltipPatterns)
    }

    private var madeFrom: LookupPresets.Preset? { preset.flatMap(LookupPresets.Preset.init(rawValue:)) }

    private static func merged(_ builtIn: [String], _ own: [String]) -> [String] {
        var seen = Set<String>()
        return (builtIn + own).filter { seen.insert($0).inserted }
    }
}

struct LookupSource: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case website
        case mediaWiki
        case weebly
        case wowhead
        // No index: ~22 000 items at 50 per API request is too many to crawl, so it is queried.
        // The home's first path component is the language (`https://dofusdb.fr/fr`).
        case dofusDB

        var title: String {
            switch self {
            case .website: return "Website"
            case .mediaWiki: return "MediaWiki"
            case .weebly: return "Weebly site"
            case .wowhead: return "Wowhead"
            case .dofusDB: return "DofusDB"
            }
        }

        var canIndex: Bool {
            switch self {
            case .website, .mediaWiki, .weebly: return true
            case .wowhead, .dofusDB: return false
            }
        }

        var canResolve: Bool { self != .website }
    }

    var id: UUID
    var name: String
    var home: URL
    var searchURL: String
    var kind: Kind
    var indexURL: URL?
    var readerCSS: String?
    var hiddenSelectors: String?

    init(id: UUID = UUID(), name: String, home: URL, searchURL: String, kind: Kind = .website,
         indexURL: URL? = nil, readerCSS: String? = nil, hiddenSelectors: String? = nil) {
        self.id = id
        self.name = name
        self.home = home
        self.searchURL = searchURL
        self.kind = kind
        self.indexURL = indexURL
        self.readerCSS = readerCSS
        self.hiddenSelectors = hiddenSelectors
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        searchURL = try c.decodeIfPresent(String.self, forKey: .searchURL) ?? ""
        if let home = try c.decodeIfPresent(URL.self, forKey: .home) {
            self.home = home
        } else if let origin = Self.origin(of: searchURL) {
            home = origin
        } else {
            throw DecodingError.keyNotFound(CodingKeys.home, .init(codingPath: c.codingPath, debugDescription: "a source needs a home or a search URL"))
        }
        // An unknown kind (from a newer version) reads as a website; throwing would drop the game.
        let kindName = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? nil
        kind = kindName.flatMap(Kind.init(rawValue:)) ?? .website
        if let kindName, Kind(rawValue: kindName) == nil {
            Settings.log("lookup: source \"\(name)\" is of a kind this version does not know (\(kindName)), read as a website")
        }
        indexURL = try c.decodeIfPresent(URL.self, forKey: .indexURL)
        readerCSS = try c.decodeIfPresent(String.self, forKey: .readerCSS)
        hiddenSelectors = try c.decodeIfPresent(String.self, forKey: .hiddenSelectors)
    }

    var host: String { Self.bareHost(of: home) ?? "" }

    static func bareHost(of url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    func searchURL(for query: String) -> URL? {
        let template = searchURL.trimmingCharacters(in: .whitespaces)
        guard !template.isEmpty else { return nil }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query
        return URL(string: template.replacingOccurrences(of: "{query}", with: encoded))
    }

    static func origin(of urlString: String) -> URL? {
        guard var components = URLComponents(string: urlString.replacingOccurrences(of: "{query}", with: "q")),
              components.host != nil, ["http", "https"].contains(components.scheme?.lowercased() ?? "") else { return nil }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }
}

final class LookupStore {
    static let shared = LookupStore()

    static let gamesKey = "lookupGames"
    static let activeGameKey = "lookupActiveGame"
    static let autoDetectKey = "lookupAutoDetect"
    static let gamesVersionKey = "lookupGamesVersion"
    static let gamesVersion = 1
    // Pre-migration backup: builds before version 1 cannot read a DofusDB source and would drop
    // that game on their next save.
    static let gamesBeforeMigrationKey = "lookupGames.v0"

    private let d = UserDefaults.standard

    // Guards `_games`: read from the warm-up queue and hotkey tasks, written on the main thread.
    private let lock = NSLock()
    private var _games: [LookupGame] = []
    // Stored games existed but none decoded: persist refuses so it cannot overwrite them with
    // nothing, until `replaceAll`.
    private var loadFailed = false

    var games: [LookupGame] { lock.withLock { _games } }

    private init() {
        d.register(defaults: [Self.autoDetectKey: true])
        if let data = Self.storedGames(in: d) {
            let stored = Self.decodeGames(data)
            _games = stored.games
            loadFailed = stored.failed
        } else {
            _games = [LookupPresets.make(.dofus)]
            persist(notify: false)
        }
    }

    // Earlier builds stored a Data blob rather than JSON text.
    private static func storedGames(in d: UserDefaults) -> Data? {
        if let text = d.string(forKey: gamesKey) { return Data(text.utf8) }
        return d.data(forKey: gamesKey)
    }

    // Decoded element by element so one unreadable game does not drop the rest.
    private static func decodeGames(_ data: Data) -> (games: [LookupGame], failed: Bool) {
        guard let elements = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else {
            Settings.log("lookup: stored games are not a list, leaving them as they are")
            return ([], true)
        }
        var games: [LookupGame] = []
        var dropped = 0
        for element in elements {
            guard JSONSerialization.isValidJSONObject(element),
                  let one = try? JSONSerialization.data(withJSONObject: element),
                  let game = try? decoder.decode(LookupGame.self, from: one) else { dropped += 1; continue }
            games.append(game)
        }
        if dropped > 0 { Settings.log("lookup: \(dropped) stored game(s) could not be read and were left out") }
        return (games, games.isEmpty && !elements.isEmpty)
    }

    func migrate() {
        let from = d.integer(forKey: Self.gamesVersionKey)
        guard from < Self.gamesVersion else { return }
        let (failed, added): (Bool, [String]) = lock.withLock {
            guard !loadFailed else { return (true, []) }
            var added: [String] = []
            for i in _games.indices where _games[i].preset == LookupPresets.Preset.dofus.rawValue
                && !_games[i].sources.contains(where: { $0.host == LookupPresets.dofusDBHost }) {
                _games[i].sources.append(LookupPresets.dofusDB(language: "fr"))
                added.append(_games[i].name)
            }
            return (false, added)
        }
        guard !failed else {
            Settings.log("lookup: games on disk could not be read, leaving their migration for later")
            return
        }
        if !added.isEmpty {
            if let stored = d.object(forKey: Self.gamesKey) { d.set(stored, forKey: Self.gamesBeforeMigrationKey) }
            persist()
        }
        d.set(Self.gamesVersion, forKey: Self.gamesVersionKey)
        Settings.log("lookup: games format \(from) -> \(Self.gamesVersion): "
                     + (added.isEmpty ? "nothing to change" : "added DofusDB to \(added.joined(separator: ", "))"))
    }

    var autoDetect: Bool {
        get { d.bool(forKey: Self.autoDetectKey) }
        set { d.set(newValue, forKey: Self.autoDetectKey); changed(Self.autoDetectKey) }
    }

    var activeGameID: UUID? {
        get { d.string(forKey: Self.activeGameKey).flatMap(UUID.init(uuidString:)) }
        set { d.set(newValue?.uuidString ?? "", forKey: Self.activeGameKey); changed(Self.activeGameKey) }
    }

    var activeGame: LookupGame? {
        games.first { $0.id == activeGameID } ?? games.first
    }

    func game(withID id: UUID) -> LookupGame? { games.first { $0.id == id } }

    func game(named name: String) -> LookupGame? {
        let wanted = name.trimmingCharacters(in: .whitespaces)
        return games.first { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }
    }

    func game(forBundleID bundleID: String?) -> LookupGame? {
        games.first { $0.matches(bundleID: bundleID) }
    }

    func resolveGame(bundleID: String?) -> LookupGame? { resolveGame(bundleIDs: [bundleID]) }

    func resolveGame(bundleIDs: [String?]) -> LookupGame? {
        let active = activeGame
        if autoDetect {
            for bundleID in bundleIDs {
                let claiming = games.filter { $0.matches(bundleID: bundleID) }
                guard !claiming.isEmpty else { continue }
                // Every WoW version ships as the same app, so the hand-picked game breaks the tie.
                return claiming.first { $0.id == active?.id } ?? claiming[0]
            }
        }
        return active
    }

    func add(_ game: LookupGame) {
        lock.withLock { _games.append(game) }
        persist()
    }

    func update(_ game: LookupGame) {
        lock.withLock {
            if let i = _games.firstIndex(where: { $0.id == game.id }) { _games[i] = game } else { _games.append(game) }
        }
        persist()
    }

    func remove(_ id: UUID) {
        lock.withLock { _games.removeAll { $0.id == id } }
        persist()
    }

    func move(_ id: UUID, to index: Int) {
        let moved: Bool = lock.withLock {
            guard let from = _games.firstIndex(where: { $0.id == id }) else { return false }
            let game = _games.remove(at: from)
            _games.insert(game, at: max(0, min(index, _games.count)))
            return true
        }
        guard moved else { return }
        persist()
    }

    func replaceAll(_ newGames: [LookupGame]) {
        lock.withLock {
            _games = newGames
            loadFailed = false
        }
        persist()
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }()
    static let decoder = JSONDecoder()

    func exportData(_ game: LookupGame) throws -> Data { try Self.encoder.encode(game) }

    func importGame(from data: Data) throws -> LookupGame {
        var game = try Self.decoder.decode(LookupGame.self, from: data)
        game.id = UUID()
        game.sources = game.sources.map { source in
            var copy = source
            copy.id = UUID()
            return copy
        }
        return game
    }

    private func persist(notify: Bool = true) {
        let snapshot: [LookupGame]? = lock.withLock { loadFailed ? nil : _games }
        guard let snapshot else {
            Settings.log("lookup: games on disk could not be read, not writing over them")
            return
        }
        // Stored as text, not Data, so `defaults read` and `defaults write` handle it as JSON.
        if let data = try? Self.encoder.encode(snapshot), let json = String(data: data, encoding: .utf8) {
            d.set(json, forKey: Self.gamesKey)
        }
        if notify { changed(Self.gamesKey) }
    }

    private func changed(_ key: String) {
        NotificationCenter.default.post(name: Settings.didChange, object: key)
    }
}

enum LookupPresets {
    enum Preset: String, CaseIterable {
        case dofus
        case dofusRetro = "dofus-retro"
        case wow
        case wowClassic = "wow-classic"
        case wowTBC = "wow-tbc"
        case wowMoP = "wow-mop"
        case wowForever = "wow-forever"
        case osrs
        case rs3

        var title: String {
            switch self {
            case .dofus: return "Dofus"
            case .dofusRetro: return "Dofus Retro"
            case .wow: return "World of Warcraft"
            case .wowClassic: return "WoW Classic"
            case .wowTBC: return "Burning Crusade Classic"
            case .wowMoP: return "Mists of Pandaria Classic"
            case .wowForever: return "WoW: Forever"
            case .osrs: return "Old School RuneScape"
            case .rs3: return "RuneScape"
            }
        }

        var siteName: String {
            switch self {
            case .dofus: return "Dofus Wiki, DofusDB"
            case .dofusRetro: return "129Dofus Wiki"
            case .wow, .wowClassic, .wowTBC, .wowMoP, .wowForever: return "Wowhead"
            case .osrs: return "OSRS Wiki"
            case .rs3: return "RuneScape Wiki"
            }
        }

        var family: String? {
            switch self {
            case .dofus, .dofusRetro: return "Dofus"
            case .wow, .wowClassic, .wowTBC, .wowMoP, .wowForever: return "World of Warcraft"
            case .osrs, .rs3: return nil
            }
        }

        var variant: String {
            switch self {
            case .wow: return "Retail"
            case .wowClassic: return "Classic (Anniversary, Era, Hardcore)"
            case .wowTBC: return "Burning Crusade Classic"
            case .wowMoP: return "Mists of Pandaria Classic"
            case .wowForever: return "Forever"
            case .dofus: return "Dofus 3"
            case .dofusRetro: return "Dofus Retro"
            case .osrs, .rs3: return title
            }
        }

        fileprivate var wowhead: (path: String, name: String)? {
            switch self {
            case .wow: return ("", "Wowhead")
            case .wowClassic: return ("/classic", "Wowhead Classic")
            case .wowTBC: return ("/tbc", "Wowhead TBC Classic")
            case .wowMoP: return ("/mop-classic", "Wowhead MoP Classic")
            case .wowForever: return ("/forever", "Wowhead Forever")
            case .dofus, .dofusRetro, .osrs, .rs3: return nil
            }
        }
    }

    static func make(_ preset: Preset) -> LookupGame {
        switch preset {
        case .dofus:
            return LookupGame(
                name: "Dofus",
                appBundleIDs: ["com.Ankama.Dofus", "com.ankama.dofus"],
                ocrLanguages: ["en-US", "fr-FR"],
                sources: [
                    LookupSource(
                        name: "Dofus Wiki",
                        home: URL(string: "https://dofuswiki.fandom.com")!,
                        searchURL: "https://dofuswiki.fandom.com/wiki/Special:Search?query={query}",
                        kind: .mediaWiki,
                        indexURL: URL(string: "https://dofuswiki.fandom.com/api.php")),
                    dofusDB(language: "en"),
                ],
                preset: preset.rawValue)
        // Retro's bundle identifier is unknown here, so it is picked by hand or set in Settings.
        case .dofusRetro:
            return LookupGame(
                name: "Dofus Retro",
                ocrLanguages: ["en-US"],
                sources: [LookupSource(
                    name: "129Dofus Wiki",
                    home: URL(string: "https://129dofus.fandom.com")!,
                    searchURL: "https://129dofus.fandom.com/wiki/Special:Search?query={query}",
                    kind: .mediaWiki,
                    indexURL: URL(string: "https://129dofus.fandom.com/api.php"))],
                preset: preset.rawValue)
        case .wow, .wowClassic, .wowTBC, .wowMoP, .wowForever:
            let database = preset.wowhead!
            return LookupGame(
                name: preset.title,
                appBundleIDs: ["com.blizzard.worldofwarcraft"],
                sources: [LookupSource(
                    name: database.name,
                    home: URL(string: "https://www.wowhead.com" + database.path)!,
                    searchURL: "https://www.wowhead.com\(database.path)/search?q={query}",
                    kind: .wowhead)],
                preset: preset.rawValue)
        case .osrs:
            return LookupGame(
                name: "Old School RuneScape",
                appBundleIDs: ["net.runelite.launcher", "com.jagex.oldscape"],
                ocrLanguages: ["en-US"],
                sources: [LookupSource(
                    name: "OSRS Wiki",
                    home: URL(string: "https://oldschool.runescape.wiki")!,
                    searchURL: "https://oldschool.runescape.wiki/w/Special:Search?search={query}",
                    kind: .mediaWiki,
                    indexURL: URL(string: "https://oldschool.runescape.wiki/api.php"))],
                preset: preset.rawValue)
        case .rs3:
            return LookupGame(
                name: "RuneScape",
                appBundleIDs: ["com.jagex.runescape"],
                ocrLanguages: ["en-US"],
                sources: [LookupSource(
                    name: "RuneScape Wiki",
                    home: URL(string: "https://runescape.wiki")!,
                    searchURL: "https://runescape.wiki/w/Special:Search?search={query}",
                    kind: .mediaWiki,
                    indexURL: URL(string: "https://runescape.wiki/api.php"))],
                preset: preset.rawValue)
        }
    }

    static let dofusDBHost = "dofusdb.fr"

    // The migration adds the French one: it goes next to Dofus pour les Noobs, a French site.
    static func dofusDB(language: String) -> LookupSource {
        LookupSource(
            name: "DofusDB",
            home: URL(string: "https://dofusdb.fr/\(language)")!,
            searchURL: "https://dofusdb.fr/\(language)/database/items?q={query}",
            kind: .dofusDB)
    }
}

// A tooltip pattern must match nothing static in the UI, or that panel is taken for a tooltip
// (WoW's action bars show `Main Hand`, so no slot names).
extension LookupPresets.Preset {
    var builtInStripPatterns: [String] {
        switch self {
        case .wow, .wowClassic, .wowTBC, .wowMoP, .wowForever: return Self.warcraftStrip
        case .osrs, .rs3: return Self.runeScapeStrip
        case .dofus, .dofusRetro: return []
        }
    }

    var builtInTooltipPatterns: [String] {
        switch self {
        case .wow, .wowClassic, .wowTBC, .wowMoP, .wowForever: return Self.warcraftTooltip
        case .osrs, .rs3: return Self.runeScapeTooltip
        case .dofus: return Self.dofusTooltip
        // Retro's tooltips are laid out differently and have not been read yet.
        case .dofusRetro: return []
        }
    }

    private static let warcraftStrip = [
        #"\s*\((?:Dungeon|Raid|Group|Heroic|PvP|Daily|Weekly|Elite|Legendary|Scenario|Delve)\)$"#,
    ]

    // Verbs are case-sensitive and only stripped before a capital, as the game writes them, so
    // a quest such as "Enter the Abyss" keeps its first word.
    private static let runeScapeStrip = [
        #"^(?:Use|Take|Wield|Wear|Eat|Drink|Examine|Drop|Attack|Talk-to|Pickpocket|Walk here|Bank|Trade|Follow|Open|Close|Enter|Climb-up|Climb-down|Pick-up|Pick|Chop down|Mine|Net|Bait|Lure|Cage|Harpoon|Smelt|Cook|Light|Bury|Rub|Read|Check|Empty|Fill|Pray-at|Search|Inspect|Craft|Build|Remove|Deposit|Withdraw|Collect|Buy|Sell|Value|Cast)\s+(?=\p{Lu})"#,
        #"(?i)\s*/?\s*\d+\s+more\s+options?\s*$"#,
        #"(?i)\s*\(\s*level\s*-\s*\d+\s*\)"#,
        #"\s*(?:-+\s?>|→)\s*.*$"#,
    ]

    // Rank accepts `I` and `l` because OCR often reads the digit 1 as a letter.
    private static let warcraftTooltip = [
        #"(?i)^Sell Price\b"#, #"(?i)^Prix de vente\b"#,
        #"(?i)^Use:"#, #"(?i)^Utiliser\s*:"#,
        #"(?i)^Equip:"#, #"(?i)^[ÉE]quip[ée]\s*:"#,
        #"(?i)^Chance on hit:"#,
        #"(?i)^Binds (?:when|to)\b"#, #"(?i)^Lié (?:quand|au|à)\b"#, #"(?i)^Soulbound$"#,
        #"(?i)^Requires "#, #"(?i)^N[ée]cessite\b"#,
        #"(?i)^Item Level \d+"#, #"(?i)^Niveau d['’]objet\b"#,
        #"(?i)^Durability \d+"#, #"(?i)^Durabilit[ée]\b"#,
        #"(?i)^Unique\b"#,
        #"(?i)^Quest Item$"#, #"(?i)^Objet de quête$"#, #"(?i)^Crafting Reagent$"#,
        #"^Rank\s+[\dIl]+$"#, #"^Rang\s+[\dIl]+$"#,
        #"(?i)^\d+ (?:mana|rage|energy|focus|runic power|énergie|focalisation)$"#,
        #"(?i)^Instant(?: cast)?$"#, #"(?i)^Incantation imm[ée]diate"#,
        #"(?i)(?:^|\s)\d+(?:[.,]\d+)?\s*(?:sec|min|hr)s?\s+cooldown$"#,
        #"(?i)^(?:temps de )?recharge\b|\bde recharge$"#,
        #"(?i)^\d+(?:[.,]\d+)? sec cast$"#,
        #"(?i)^(?:\d+\s*-\s*)?\d+ yd range$"#,
        #"(?i)^Tools:"#, #"(?i)^Reagents:"#,
    ]

    private static let dofusTooltip = [
        #"(?i)^(?:Niveau|Level|Nivel)\s+\d+\s*[•·∙●]"#,
        #"(?i)^(?:POIDS|WEIGHT|PESO)\b"#,
        #"(?i)^(?:PRIX MOYEN|AVERAGE PRICE)\b"#,
        #"(?i)\b(?:infobulle|tooltip)\b"#,
    ]

    private static let runeScapeTooltip = [
        #"(?i)\b\d+\s+more\s+options?$"#,
        #"(?i)^Weight:"#,
    ]
}

enum LookupCache {
    static let directory: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SlyTerm", isDirectory: true)
            .appendingPathComponent("lookup", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let legacyFile: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("SlyTerm/dofuspourlesnoobs-sitemap.xml")

    static let maxAge: TimeInterval = 7 * 24 * 3600

    static func url(for source: LookupSource) -> URL {
        let host = (source.indexURL.flatMap(LookupSource.bareHost(of:)) ?? source.host)
        let safe = host.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" }
        return directory.appendingPathComponent(String(safe).isEmpty ? "index.json" : "\(String(safe)).json")
    }
}
