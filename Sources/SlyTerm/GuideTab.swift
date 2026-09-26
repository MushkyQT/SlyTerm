import AppKit
import WebKit

// Bump `identifier` whenever the rules change: WebKit caches the compiled list on disk under it.
enum GuideContent {
    static var home: URL {
        LookupStore.shared.activeGame?.primarySource?.home ?? URL(string: "https://www.dofuspourlesnoobs.com")!
    }
    private static let identifier = "slyterm-guide-v5"

    private static let blockedHosts = [
        "googlesyndication.com", "doubleclick.net", "googletagmanager.com", "google-analytics.com",
        "googleadservices.com", "sportslocalmedia.com", "appconsent.io", "analytics.dimtopia.com",
        "disqus.com", "disquscdn.com", "adnxs.com", "rubiconproject.com", "pubmatic.com",
        "criteo.com", "criteo.net", "openx.net", "casalemedia.com", "amazon-adsystem.com",
        "smartadserver.com", "3lift.com", "indexww.com", "teads.tv", "outbrain.com", "taboola.com",
        "ko-fi.com", "privacy-mgmt.com", "consensu.org", "cookielaw.org", "onetrust.com",
    ]

    private static let blockedScripts = ["adsbygoogle", "cmpcheck\\.js", "tags-management\\.js",
                                         "contributor-message\\.js", "k-top-contributors\\.js"]

    private static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static var rules: String {
        // Hosts go in url-filter: `if-domain` matches the page's domain, not the resource's.
        // `unless-domain` does too, which is what leaves a streaming site's own pages unblocked;
        // the last rule does the same for its player embedded in another site's page.
        let resources = "[\"script\",\"image\",\"style-sheet\",\"raw\",\"font\",\"media\",\"popup\"]"
        let exempt = "[" + WebSites.streamingHosts.map { quoted("*" + $0) }.joined(separator: ",") + "]"
        var list = blockedHosts.map { host -> String in
            let pattern = "^https?://([^/]+\\.)?" + host.replacingOccurrences(of: ".", with: "\\.")
            return "{\"trigger\":{\"url-filter\":\(quoted(pattern)),\"resource-type\":\(resources),"
                + "\"unless-domain\":\(exempt)},\"action\":{\"type\":\"block\"}}"
        }
        list += blockedScripts.map {
            "{\"trigger\":{\"url-filter\":\(quoted($0)),\"resource-type\":[\"script\"],"
                + "\"unless-domain\":\(exempt)},\"action\":{\"type\":\"block\"}}"
        }
        let frames = WebSites.streamingHosts.map {
            quoted("^https?://([^/]+\\.)?" + $0.replacingOccurrences(of: ".", with: "\\.") + "[:/]")
        }
        list.append("{\"trigger\":{\"url-filter\":\".*\",\"if-frame-url\":[" + frames.joined(separator: ",")
                    + "]},\"action\":{\"type\":\"ignore-previous-rules\"}}")
        return "[" + list.joined(separator: ",") + "]"
    }

    private static var ruleList: WKContentRuleList?
    private static var waiting: [(WKContentRuleList?) -> Void] = []
    private static var isCompiling = false

    static func prepare() {
        withRuleList { _ in }
        // Reads Safari's Info.plist, which the first web tab would otherwise do on the main thread.
        DispatchQueue.global(qos: .utility).async { _ = WebSites.safariUserAgentSuffix }
    }

    static func withRuleList(_ completion: @escaping (WKContentRuleList?) -> Void) {
        if let ruleList { completion(ruleList); return }
        waiting.append(completion)
        guard !isCompiling else { return }
        isCompiling = true
        let started = Date()
        let store = WKContentRuleListStore.default()
        store?.lookUpContentRuleList(forIdentifier: identifier) { list, _ in
            if let list {
                Settings.log("guide: rule list from cache in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
                ready(list)
                return
            }
            store?.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: rules) { list, error in
                if let error { Settings.log("guide: rule list failed to compile: \(error)") }
                Settings.log("guide: rule list compiled in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
                ready(list)
            }
        }
    }

    private static func ready(_ list: WKContentRuleList?) {
        ruleList = list
        isCompiling = false
        let pending = waiting
        waiting.removeAll()
        pending.forEach { $0(list) }
    }

    // Streaming services offer FairPlay only to Safari's user agent. Element fullscreen stays off:
    // it opens a Space of its own, away from the game; WebMedia's shim fills the view instead.
    static func configuration(reader: Bool) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.applicationNameForUserAgent = WebSites.safariUserAgentSuffix
        configuration.mediaTypesRequiringUserActionForPlayback = []
        // On by default on macOS, where a page's timer could open tab after tab over the game.
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        addScripts(to: configuration.userContentController, reader: reader)
        return configuration
    }

    static func addScripts(to controller: WKUserContentController, reader: Bool) {
        controller.addUserScript(userScript(reader: reader))
        WebMedia.userScripts().forEach { controller.addUserScript($0) }
    }

    struct SiteStyle {
        var readerCSS: String?
        var hiddenSelectors: String?
        var contentSelector: String?
        var imageBlockSelector: String?
    }

    private static let builtInStyles: [String: SiteStyle] = [
        "dofuspourlesnoobs.com": SiteStyle(
            readerCSS: inversion + "\n" + weeblyStylesheet,
            hiddenSelectors: "[id^=\"Dofuspourlesnoobs_\"], .akcelo-wrapper, ins.adsbygoogle, "
                + "#floatDonationDpln, #customer-accounts-app",
            contentSelector: "#wsite-content",
            imageBlockSelector: ".wsite-image"),
        "wowhead.com": SiteStyle(
            readerCSS: wowheadStylesheet,
            hiddenSelectors: "[class*=\"cnx-ad\"], .zaf-block, #newsletter-cta-wrapper, .adsbox, "
                + "#onetrust-consent-sdk"),
    ]

    private static let fallbackKey = "*"

    private static func defaultStyle(for kind: LookupSource.Kind) -> SiteStyle {
        switch kind {
        case .mediaWiki:
            return SiteStyle(readerCSS: inversion + "\n" + mediaWikiStylesheet,
                             hiddenSelectors: ".top-ads-container, .bottom-ads-container, .ad-slot, .gpt-ad, "
                                 + "[class*=\"wikigg-showcase\"], [id^=\"wikigg-sl-\"], [id^=\"sp_message_container\"]")
        default:
            return SiteStyle(readerCSS: inversion + "\n" + genericStylesheet)
        }
    }

    private static func builtInStyle(forHost host: String) -> SiteStyle? {
        var best: (suffix: String, style: SiteStyle)?
        for (suffix, style) in builtInStyles where host == suffix || host.hasSuffix("." + suffix) {
            if best == nil || suffix.count > best!.suffix.count { best = (suffix, style) }
        }
        return best?.style
    }

    static func siteStyles() -> [String: SiteStyle] {
        var styles = builtInStyles
        styles[fallbackKey] = SiteStyle(readerCSS: inversion + "\n" + genericStylesheet)
        for source in LookupStore.shared.games.flatMap({ $0.sources }) {
            let host = source.host
            guard !host.isEmpty else { continue }
            var style = styles[host] ?? builtInStyle(forHost: host) ?? defaultStyle(for: source.kind)
            if let extra = trimmed(source.readerCSS) {
                style.readerCSS = [style.readerCSS, extra].compactMap { $0 }.joined(separator: "\n")
            }
            if let extra = trimmed(source.hiddenSelectors) {
                style.hiddenSelectors = [style.hiddenSelectors, extra].compactMap { $0 }.joined(separator: ", ")
            }
            styles[host] = style
        }
        return styles
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    // U+2028/U+2029 are valid in JSON but end a JavaScript string; `<` is escaped so no value can
    // close a <script> tag.
    private static func literal(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
              let text = String(data: data, encoding: .utf8) else { return "null" }
        return text.replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
            .replacingOccurrences(of: "<", with: "\\u003c")
    }

    private static func stylesLiteral() -> String {
        var object: [String: [String: String]] = [:]
        for (host, style) in siteStyles() {
            var entry: [String: String] = [:]
            entry["css"] = style.readerCSS
            entry["hidden"] = style.hiddenSelectors
            entry["content"] = style.contentSelector
            entry["imageBlock"] = style.imageBlockSelector
            object[host] = entry
        }
        return literal(object)
    }

    private static let baseStylesheet = """
    html.slyterm-reader img {
      max-width: 100% !important;
      height: auto !important;
      border-radius: 6px;
    }
    html.slyterm-reader .slyterm-gallery {
      display: flex;
      flex-wrap: wrap;
      justify-content: center;
      align-items: flex-start;
      gap: 6px;
      padding: 4px 0;
    }
    html.slyterm-reader .slyterm-slot,
    html.slyterm-reader .slyterm-emptied {
      display: none !important;
    }
    html.slyterm-reader body { overflow-x: hidden }
    /* WebKit styles a highlight from the element holding the text, not the root, hence `*`.
       Reader colours are pre-inverted: the highlight goes through the root's filter. */
    ::highlight(slyterm-find) { background-color: #ffe14d; color: #000 }
    ::highlight(slyterm-find-current) { background-color: #ff9d2e; color: #000 }
    html.slyterm-reader *::highlight(slyterm-find) { background-color: #a04100; color: #fff }
    html.slyterm-reader *::highlight(slyterm-find-current) { background-color: #ff5a05; color: #fff }
    """

    private static let inversion = """
    html.slyterm-reader {
      color-scheme: dark;
      filter: invert(0.92) hue-rotate(180deg);
      background: transparent !important;
    }
    html.slyterm-reader img,
    html.slyterm-reader video,
    html.slyterm-reader iframe,
    html.slyterm-reader canvas,
    html.slyterm-reader svg {
      filter: invert(1) hue-rotate(180deg);
    }
    """

    private static let weeblyStylesheet = """
    html.slyterm-reader body,
    html.slyterm-reader #main-wrap,
    html.slyterm-reader #main-wrap .container,
    html.slyterm-reader #wsite-content,
    html.slyterm-reader .wsite-background,
    html.slyterm-reader .wsite-custom-background {
      background: transparent !important;
      background-image: none !important;
      box-shadow: none !important;
      border: 0 !important;
    }
    html.slyterm-reader #header-wrap,
    html.slyterm-reader #nav-wrap,
    html.slyterm-reader #banner,
    html.slyterm-reader #leftside-col,
    html.slyterm-reader #footer-wrap,
    html.slyterm-reader .promo,
    html.slyterm-reader .promobis,
    html.slyterm-reader .promo3,
    html.slyterm-reader .promo4,
    html.slyterm-reader #dplnContriBottom,
    html.slyterm-reader #dpln-recommendation,
    html.slyterm-reader #disqus_thread,
    html.slyterm-reader #contriFooter,
    html.slyterm-reader .wsite-social,
    html.slyterm-reader .wsite-search,
    html.slyterm-reader #commentArea,
    html.slyterm-reader .scrollToTop,
    html.slyterm-reader .wcustomhtml:has(> #disqus_thread) {
      display: none !important;
    }
    html.slyterm-reader td:has(> #leftside-col) { display: none !important }
    html.slyterm-reader #main-wrap > table,
    html.slyterm-reader #main-wrap > table > tbody,
    html.slyterm-reader #main-wrap > table > tbody > tr,
    html.slyterm-reader #main-wrap > table > tbody > tr > td:not(:has(> #leftside-col)) {
      display: block !important;
      width: auto !important;
    }
    html.slyterm-reader #main-wrap .container {
      max-width: none !important;
      width: auto !important;
      margin: 0 !important;
      padding: 0 14px !important;
    }
    html.slyterm-reader #main-wrap { padding-top: 0 !important }
    html.slyterm-reader #wsite-content {
      width: auto !important;
      padding: 8px 0 16px !important;
    }
    html.slyterm-reader #wsite-content,
    html.slyterm-reader #wsite-content p,
    html.slyterm-reader #wsite-content div,
    html.slyterm-reader #wsite-content span,
    html.slyterm-reader #wsite-content li,
    html.slyterm-reader #wsite-content td,
    html.slyterm-reader #wsite-content font {
      font-family: -apple-system, system-ui, sans-serif !important;
      font-size: 14px !important;
      line-height: 1.5 !important;
    }
    html.slyterm-reader #main-wrap h2 {
      font-size: 22px !important;
      line-height: 1.25 !important;
      margin: 10px 0 !important;
      overflow-wrap: normal !important;
      word-break: normal !important;
    }
    html.slyterm-reader #wsite-content .wsite-image {
      padding: 4px 0 !important;
    }
    html.slyterm-reader #wsite-content .wsite-image img {
      width: auto !important;
      max-width: 70% !important;
      max-height: 180px !important;
      cursor: zoom-in;
    }
    /* Keep #wsite-content in these selectors, or the lone-screenshot rules win on specificity. */
    html.slyterm-reader #wsite-content .slyterm-gallery .wsite-image {
      flex: 0 1 auto;
      max-width: calc(50% - 3px);
      padding: 0 !important;
      margin: 0 !important;
    }
    html.slyterm-reader #wsite-content .slyterm-gallery .wsite-image img {
      max-height: 88px !important;
      max-width: 100% !important;
    }
    html.slyterm-reader #wsite-content .slyterm-gallery .wsite-image.slyterm-expanded {
      flex-basis: 100%;
      max-width: 100%;
    }
    html.slyterm-reader #wsite-content .wsite-image.slyterm-expanded img {
      max-width: 100% !important;
      max-height: none !important;
      height: auto !important;
      cursor: zoom-out;
    }
    html.slyterm-reader .wsite-multicol-table,
    html.slyterm-reader .wsite-multicol-tbody,
    html.slyterm-reader .wsite-multicol-tr,
    html.slyterm-reader .wsite-multicol-col {
      display: block !important;
      width: 100% !important;
    }
    html.slyterm-reader .wsite-multicol-col {
      box-sizing: border-box !important;
      padding: 0 !important;
    }
    html.slyterm-reader .wsite-multicol-table-wrap { margin: 0 !important }
    html.slyterm-reader .dungeon-last-update {
      background-color: #ededf0 !important;
      border-color: #cfcfd4 !important;
    }
    html.slyterm-reader a { text-decoration: none }
    html.slyterm-reader hr { margin: 10px 0 !important; border-width: 1px 0 0 0 !important }
    html.slyterm-reader .wsite-spacer { height: 8px !important }
    """

    private static let mediaWikiStylesheet = """
    html.slyterm-reader.skin-theme-clientpref-night,
    html.slyterm-reader.theme-dark,
    html.slyterm-reader.view-dark {
      filter: none !important;
    }
    html.slyterm-reader.skin-theme-clientpref-night img,
    html.slyterm-reader.theme-dark img,
    html.slyterm-reader.view-dark img,
    html.slyterm-reader.skin-theme-clientpref-night video,
    html.slyterm-reader.theme-dark video,
    html.slyterm-reader.view-dark video,
    html.slyterm-reader.skin-theme-clientpref-night svg,
    html.slyterm-reader.theme-dark svg,
    html.slyterm-reader.view-dark svg {
      filter: none !important;
    }
    html.slyterm-reader body,
    html.slyterm-reader .mw-page-container,
    html.slyterm-reader .mw-page-container-inner,
    html.slyterm-reader .mw-content-container,
    html.slyterm-reader .mw-body,
    html.slyterm-reader .mw-body-content,
    html.slyterm-reader .vector-body,
    html.slyterm-reader #content,
    html.slyterm-reader #mw-content-text,
    html.slyterm-reader .page-content,
    html.slyterm-reader .page__main,
    html.slyterm-reader .main-container,
    html.slyterm-reader .resizable-container {
      background: transparent !important;
      background-image: none !important;
      box-shadow: none !important;
      border: 0 !important;
      max-width: none !important;
      width: auto !important;
      margin: 0 !important;
    }
    html.slyterm-reader #mw-navigation,
    html.slyterm-reader #mw-panel,
    html.slyterm-reader #mw-head,
    html.slyterm-reader .vector-header-container,
    html.slyterm-reader .vector-sitenotice-container,
    html.slyterm-reader .vector-page-toolbar,
    html.slyterm-reader .vector-column-start,
    html.slyterm-reader .vector-column-end,
    html.slyterm-reader .vector-settings,
    html.slyterm-reader #siteNotice,
    html.slyterm-reader #footer,
    html.slyterm-reader .mw-footer-container,
    html.slyterm-reader .mw-editsection,
    html.slyterm-reader #p-lang,
    html.slyterm-reader .mw-indicators,
    html.slyterm-reader #jump-to-nav,
    html.slyterm-reader .mw-jump-link,
    html.slyterm-reader #catlinks,
    html.slyterm-reader .printfooter,
    html.slyterm-reader body > header,
    html.slyterm-reader body > footer,
    html.slyterm-reader .page-header__actions,
    html.slyterm-reader #WikiaBar,
    html.slyterm-reader .global-navigation,
    html.slyterm-reader .fandom-sticky-header,
    html.slyterm-reader .right-rail,
    html.slyterm-reader #mixed-content-footer,
    html.slyterm-reader .wds-global-footer,
    html.slyterm-reader .top-ads-container,
    html.slyterm-reader .bottom-ads-container,
    html.slyterm-reader #WikiaRail,
    html.slyterm-reader .notifications-placeholder,
    html.slyterm-reader .community-header-wrapper,
    html.slyterm-reader .wiki-tools,
    html.slyterm-reader .page-side-tools {
      display: none !important;
    }
    html.slyterm-reader body,
    html.slyterm-reader #content,
    html.slyterm-reader #mw-content-text {
      font-family: -apple-system, system-ui, sans-serif !important;
      font-size: 14px !important;
      line-height: 1.5 !important;
      padding: 8px 14px 16px !important;
    }
    html.slyterm-reader #content,
    html.slyterm-reader #mw-content-text { padding: 0 !important }
    html.slyterm-reader .mw-first-heading,
    html.slyterm-reader #firstHeading,
    html.slyterm-reader .page-header__title {
      font-size: 22px !important;
      line-height: 1.25 !important;
      margin: 0 0 10px !important;
    }
    html.slyterm-reader #mw-content-text h2 { font-size: 18px !important }
    html.slyterm-reader #mw-content-text h3 { font-size: 15px !important }
    html.slyterm-reader .infobox,
    html.slyterm-reader .infobox-wrapper,
    html.slyterm-reader .portable-infobox,
    html.slyterm-reader table.wikitable {
      float: none !important;
      max-width: 100% !important;
      margin: 8px 0 !important;
    }
    html.slyterm-reader .thumb,
    html.slyterm-reader .tright,
    html.slyterm-reader .tleft,
    html.slyterm-reader figure {
      float: none !important;
      width: auto !important;
      max-width: 100% !important;
      margin: 8px 0 !important;
    }
    html.slyterm-reader .infobox td,
    html.slyterm-reader .infobox th,
    html.slyterm-reader table.wikitable td,
    html.slyterm-reader table.wikitable th {
      padding: 3px 6px !important;
      font-size: 13px !important;
    }
    html.slyterm-reader table.wikitable {
      display: block;
      width: fit-content;
      overflow-x: auto;
    }
    html.slyterm-reader [class*="cookie"],
    html.slyterm-reader [id*="cookie"],
    html.slyterm-reader [class*="consent"],
    html.slyterm-reader [id*="consent"],
    html.slyterm-reader [class*="qc-cmp"] {
      display: none !important;
    }
    html.slyterm-reader a { text-decoration: none }
    """

    private static let wowheadStylesheet = """
    html.slyterm-reader { color-scheme: dark; background: transparent !important }
    html.slyterm-reader body,
    html.slyterm-reader .layout-wrapper,
    html.slyterm-reader .layout,
    html.slyterm-reader #page-content,
    html.slyterm-reader #main,
    html.slyterm-reader #main-contents {
      background: transparent !important;
      background-image: none !important;
      box-shadow: none !important;
      border: 0 !important;
      max-width: none !important;
      width: auto !important;
      margin: 0 !important;
      padding: 0 !important;
    }
    html.slyterm-reader #zul-bar,
    html.slyterm-reader #zul-bar-mobile-content,
    html.slyterm-reader #zul-bar-mobile-menu-back-row,
    html.slyterm-reader #footer,
    html.slyterm-reader #sidebar,
    html.slyterm-reader .blocks,
    html.slyterm-reader .database-detail-page-comments,
    html.slyterm-reader .infobox-changelog {
      display: none !important;
    }
    html.slyterm-reader body {
      font-family: -apple-system, system-ui, sans-serif !important;
      font-size: 14px !important;
      line-height: 1.5 !important;
      padding: 8px 14px 16px !important;
    }
    html.slyterm-reader h1 { font-size: 22px !important; line-height: 1.25 !important }
    html.slyterm-reader h2 { font-size: 18px !important }
    html.slyterm-reader a { text-decoration: none }
    """

    private static let genericStylesheet = """
    html.slyterm-reader body {
      background: transparent !important;
      background-image: none !important;
      max-width: none !important;
      width: auto !important;
      margin: 0 !important;
      padding: 8px 14px 16px !important;
      font-family: -apple-system, system-ui, sans-serif !important;
      font-size: 14px !important;
      line-height: 1.5 !important;
    }
    html.slyterm-reader header,
    html.slyterm-reader nav,
    html.slyterm-reader footer,
    html.slyterm-reader aside,
    html.slyterm-reader [role=banner],
    html.slyterm-reader [role=navigation],
    html.slyterm-reader [role=complementary],
    html.slyterm-reader [role=contentinfo],
    html.slyterm-reader .sidebar,
    html.slyterm-reader #sidebar,
    html.slyterm-reader .ads,
    html.slyterm-reader .ad,
    html.slyterm-reader .advert,
    html.slyterm-reader [class*="cookie"],
    html.slyterm-reader [id*="cookie"],
    html.slyterm-reader [class*="consent"],
    html.slyterm-reader [id*="consent"] {
      display: none !important;
    }
    html.slyterm-reader h1 { font-size: 22px !important; line-height: 1.25 !important }
    html.slyterm-reader h2 { font-size: 18px !important }
    html.slyterm-reader h3 { font-size: 15px !important }
    html.slyterm-reader a { text-decoration: none }
    """

    static func userScript(reader: Bool) -> WKUserScript {
        let source = """
        (function () {
          var root = document.documentElement;
          if (!root) return;
          if (window.__slyterm) { window.__slyterm.setReader(\(reader)); return; }

          var hostname = (location.hostname || "").toLowerCase();
          var streaming = \(literal(WebSites.streamingHosts)).some(function (suffix) {
            return hostname === suffix || hostname.endsWith("." + suffix);
          });

          // The page's own <html class> parse, and a wiki's later rewrite of it, drop the reader
          // class; the observer runs as a microtask, so it is restored before any paint.
          var wanted = \(reader) && !streaming;
          function applyReader() { root.classList.toggle("slyterm-reader", wanted); }
          applyReader();
          new MutationObserver(function () {
            if (root.classList.contains("slyterm-reader") !== wanted) applyReader();
          }).observe(root, { attributes: true, attributeFilter: ["class"] });

          var styles = \(stylesLiteral());
          var site = styles["\(fallbackKey)"] || {};
          var host = (location.host || "").toLowerCase(), best = 0;
          for (var key in styles) {
            if (key === "\(fallbackKey)" || key.length <= best) continue;
            if (host === key || host.endsWith("." + key)) { site = styles[key]; best = key.length; }
          }
          var blocks = site.content && site.imageBlock ? site.content + " " + site.imageBlock : null;

          var style = document.createElement("style");
          style.id = "slyterm-style";
          style.textContent = \(literal(baseStylesheet)) + "\\n" + (site.css || "");
          (document.head || root).appendChild(style);

          // Own sheet so a user stylesheet's unclosed brace cannot swallow it; `:is()` is
          // forgiving, so one invalid user selector does not void the whole list.
          if (site.hidden) {
            var hidden = document.createElement("style");
            hidden.id = "slyterm-hidden";
            hidden.textContent = ":is(" + site.hidden + "){display:none !important}";
            (document.head || root).appendChild(hidden);
          }

          function isReader() { return root.classList.contains("slyterm-reader"); }
          function article() { return site.content ? document.querySelector(site.content) : null; }

          function runs() {
            var content = article();
            if (!content || !site.imageBlock) return [];
            var walker = document.createTreeWalker(content, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, {
              acceptNode: function (node) {
                var parent = node.parentNode;
                if (parent && parent.closest && parent.closest(site.imageBlock)) return NodeFilter.FILTER_REJECT;
                if (node.nodeType === 3) return node.nodeValue.trim() ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_SKIP;
                var tag = node.tagName;
                if (tag === "SCRIPT" || tag === "STYLE" || tag === "NOSCRIPT") return NodeFilter.FILTER_REJECT;
                if (node.classList.contains("slyterm-gallery")) return NodeFilter.FILTER_REJECT;
                if (node.matches(site.imageBlock) || tag === "IMG" || tag === "IFRAME" || tag === "HR") return NodeFilter.FILTER_ACCEPT;
                return NodeFilter.FILTER_SKIP;
              }
            });
            var found = [], run = [], node;
            while ((node = walker.nextNode())) {
              if (node.nodeType === 1 && node.matches(site.imageBlock)) { run.push(node); continue; }
              if (run.length > 1) found.push(run);
              run = [];
            }
            if (run.length > 1) found.push(run);
            return found;
          }

          function hideEmptied(from) {
            var content = article();
            var el = from.parentNode;
            while (el && el !== content && el.nodeType === 1) {
              if (el.textContent.trim() || el.querySelector("img, iframe, .slyterm-gallery")) break;
              el.classList.add("slyterm-emptied");
              el = el.parentNode;
            }
          }

          function group() {
            if (!blocks) return;
            if (document.querySelector(".slyterm-gallery")) return;
            runs().forEach(function (run) {
              var gallery = document.createElement("div");
              gallery.className = "slyterm-gallery";
              run[0].parentNode.insertBefore(gallery, run[0]);
              run.forEach(function (block) {
                var slot = document.createElement("span");
                slot.className = "slyterm-slot";
                block.parentNode.insertBefore(slot, block);
                block.slytermSlot = slot;
                gallery.appendChild(block);
                hideEmptied(slot);
              });
            });
          }

          function ungroup() {
            Array.prototype.slice.call(document.querySelectorAll(".slyterm-gallery")).forEach(function (gallery) {
              Array.prototype.slice.call(gallery.children).forEach(function (block) {
                var slot = block.slytermSlot;
                if (slot && slot.parentNode) {
                  slot.parentNode.insertBefore(block, slot);
                  slot.parentNode.removeChild(slot);
                }
              });
              gallery.parentNode.removeChild(gallery);
            });
            Array.prototype.slice.call(document.querySelectorAll(".slyterm-emptied, .slyterm-expanded")).forEach(function (el) {
              el.classList.remove("slyterm-emptied");
              el.classList.remove("slyterm-expanded");
            });
          }

          window.__slyterm = {
            setReader: function (on) {
              wanted = on && !streaming;
              applyReader();
              if (document.readyState === "loading") return;
              if (wanted) group(); else ungroup();
            }
          };
          document.addEventListener("DOMContentLoaded", function () { if (isReader()) group(); });

          function scrollTop(y) {
            window.scrollTo({ top: Math.max(0, y), left: 0, behavior: "instant" });
          }

          function expand(block) {
            var top = block.getBoundingClientRect().top;
            block.classList.add("slyterm-expanded");
            scrollTop(window.scrollY + block.getBoundingClientRect().top - top);
            block.slytermAnchor = window.scrollY;
          }

          function shrink(block) {
            var anchor = block.slytermAnchor;
            var group = block.closest(".slyterm-gallery") || block;
            var top = block.getBoundingClientRect().top;
            var bottom = group.getBoundingClientRect().bottom;
            var stayed = anchor !== undefined && Math.abs(window.scrollY - anchor) < 2;
            block.classList.remove("slyterm-expanded");
            delete block.slytermAnchor;
            var moved = block.getBoundingClientRect().top - top;
            if (stayed) scrollTop(anchor + moved);
            else if (top >= 0) scrollTop(window.scrollY + moved);
            else scrollTop(window.scrollY - (bottom - group.getBoundingClientRect().bottom));
          }

          // Capture phase, to beat the site's link and lightbox: the root's filter breaks its
          // position: fixed.
          document.addEventListener("click", function (event) {
            if (!isReader() || !blocks || !event.target.closest) return;
            var block = event.target.closest(blocks);
            if (!block) return;
            event.preventDefault();
            event.stopImmediatePropagation();
            if (block.classList.contains("slyterm-expanded")) shrink(block); else expand(block);
          }, true);
          document.addEventListener("keydown", function (event) {
            if (event.key !== "Escape" || !isReader()) return;
            // Last first: shrinking a block moves those below it and stales their measurements.
            var open = Array.prototype.slice.call(document.querySelectorAll(".slyterm-expanded"));
            while (open.length) shrink(open.pop());
          });

          var finding = { query: "", ranges: [], index: -1 };
          var folded = {};

          // Must map one character to one, or match offsets no longer map back to the page.
          function fold(ch) {
            var f = folded[ch];
            if (f === undefined) {
              f = ch.normalize("NFD").replace(/[\\u0300-\\u036f]/g, "").toLowerCase();
              if (f.length !== 1) f = ch.toLowerCase();
              if (f.length !== 1) f = ch;
              folded[ch] = f;
            }
            return f;
          }

          function isSpace(ch) {
            return ch === " " || ch === "\\n" || ch === "\\t" || ch === "\\r" || ch === "\\f" || ch === "\\u00a0";
          }

          function pageText() {
            var nodes = [], nodeOf = [], offsetOf = [], text = [], space = true;
            var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
              acceptNode: function (node) {
                var tag = node.parentNode && node.parentNode.tagName;
                var skip = tag === "SCRIPT" || tag === "STYLE" || tag === "NOSCRIPT" || tag === "TEXTAREA";
                return skip ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT;
              }
            });
            var node;
            while ((node = walker.nextNode())) {
              var value = node.nodeValue, n = nodes.push(node) - 1;
              for (var i = 0; i < value.length; i++) {
                var ch = value[i];
                if (isSpace(ch)) {
                  if (space) continue;
                  space = true;
                  text.push(" ");
                } else {
                  space = false;
                  text.push(fold(ch));
                }
                nodeOf.push(n);
                offsetOf.push(i);
              }
            }
            return { nodes: nodes, nodeOf: nodeOf, offsetOf: offsetOf, text: text.join("") };
          }

          function matches(query) {
            var q = [], space = true;
            for (var i = 0; i < query.length; i++) {
              var ch = query[i];
              if (isSpace(ch)) { if (!space) { q.push(" "); space = true; } }
              else { q.push(fold(ch)); space = false; }
            }
            q = q.join("").trim();
            if (!q || !document.body) return [];
            var page = pageText(), found = [], from = 0, at;
            while ((at = page.text.indexOf(q, from)) !== -1) {
              from = at + q.length;
              var last = from - 1;
              var range = document.createRange();
              range.setStart(page.nodes[page.nodeOf[at]], page.offsetOf[at]);
              range.setEnd(page.nodes[page.nodeOf[last]], page.offsetOf[last] + 1);
              if (range.getClientRects().length) found.push(range);
            }
            return found;
          }

          function paint() {
            if (!window.Highlight || !CSS.highlights) {
              var selection = window.getSelection();
              selection.removeAllRanges();
              if (finding.index >= 0) selection.addRange(finding.ranges[finding.index]);
              return;
            }
            var others = new Highlight(), current = new Highlight();
            finding.ranges.forEach(function (range, i) { (i === finding.index ? current : others).add(range); });
            current.priority = 1;
            CSS.highlights.set("slyterm-find", others);
            CSS.highlights.set("slyterm-find-current", current);
          }

          function reveal(range) {
            var rect = range.getBoundingClientRect(), margin = 40;
            if (rect.top >= margin && rect.bottom <= window.innerHeight - margin) return;
            scrollTop(window.scrollY + rect.top - (window.innerHeight - rect.height) / 2);
          }

          function sameStart(a, b) {
            try { return a.compareBoundaryPoints(Range.START_TO_START, b) === 0; } catch (e) { return false; }
          }

          function find(query, step, jump) {
            var previous = finding.index >= 0 ? finding.ranges[finding.index] : null;
            if (step === 0 || query !== finding.query) {
              finding = { query: query, ranges: matches(query), index: -1 };
              var ranges = finding.ranges, i;
              if (previous) {
                for (i = 0; i < ranges.length && finding.index < 0; i++) {
                  if (sameStart(ranges[i], previous)) finding.index = i;
                }
              }
              for (i = 0; i < ranges.length && finding.index < 0; i++) {
                if (ranges[i].getBoundingClientRect().bottom >= 0) finding.index = i;
              }
              if (finding.index < 0 && ranges.length) finding.index = 0;
            } else if (finding.ranges.length) {
              finding.index = (finding.index + step + finding.ranges.length) % finding.ranges.length;
            }
            paint();
            if (jump && finding.index >= 0) reveal(finding.ranges[finding.index]);
            return { count: finding.ranges.length, index: finding.index + 1 };
          }

          function findDone(keep) {
            var current = finding.index >= 0 ? finding.ranges[finding.index] : null;
            finding = { query: "", ranges: [], index: -1 };
            if (window.Highlight && CSS.highlights) {
              CSS.highlights.delete("slyterm-find");
              CSS.highlights.delete("slyterm-find-current");
            }
            var selection = window.getSelection();
            selection.removeAllRanges();
            if (keep && current) selection.addRange(current);
          }

          window.__slyterm.find = find;
          window.__slyterm.findDone = findDone;
        })();
        """
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }
}

final class GuideTab: NSObject, Tab, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, NSTextFieldDelegate {
    static let toolbarHeight: CGFloat = 26
    static let toolbarColor = NSColor(calibratedRed: 0.12, green: 0.12, blue: 0.14, alpha: 1)

    let id = UUID()
    let contentView: NSView
    let webView: WKWebView
    let toolbar: GuideToolbarView
    let pageView: NSView
    weak var host: WebTabHost?
    var openedByLookup = false
    private(set) var place = WebTabPlace.docked
    private(set) var media = WebMediaState.none
    private(set) var favicon: NSImage?
    var url: URL? { webView.url }
    var isEditingText: Bool { isEditing(findBar.field) || isEditing(addressField) }
    var focusView: NSView { isFinding ? findBar.field : webView }
    private(set) var title: String { didSet { if title != oldValue { onTitleChange?() } } }
    var needsAttention = false { didSet { if needsAttention != oldValue { onAttentionChange?() } } }
    var onTitleChange: (() -> Void)?
    var onAttentionChange: (() -> Void)?
    var onLoadEnd: ((Error?) -> Void)?

    private(set) var isReaderMode: Bool
    private let progress = NSView(frame: .zero)
    private let addressField = GuideAddressField(frame: .zero)
    private var isEditingAddress = false
    private var backButton: NSButton!
    private var forwardButton: NSButton!
    private var findButton: NSButton!
    private var readerButton: NSButton!
    private var placeButton: NSButton!
    private var browserButton: NSButton!
    private var closeButton: NSButton!
    private let findBar = GuideFindBar(frame: .zero)
    private(set) var isFinding = false
    private var observations: [NSKeyValueObservation] = []
    private var pendingURL: URL?
    private var hasRules = false
    private var failedURL: URL?
    private var mediaFrames = WebMediaFrames()
    private var faviconSite: String?
    private var popups: [Date] = []
    private var mediaPoll: Timer?
    private var webKitPlaying = false
    private var pauseSuspended = false
    private var panicSuspended = false
    private var isSuspended = false

    init(frame: NSRect, url: URL?, reader: Bool = true) {
        isReaderMode = reader
        title = url == nil ? "New tab" : "Guide"
        let content = GuideLayoutView(frame: frame)
        let page = GuideLayoutView(frame: NSRect(x: 0, y: 0, width: frame.width,
                                                 height: max(0, frame.height - GuideTab.toolbarHeight)))
        contentView = content
        pageView = page
        toolbar = GuideToolbarView(frame: NSRect(x: 0, y: page.frame.height, width: frame.width,
                                                 height: GuideTab.toolbarHeight))
        webView = GuideWebView(frame: page.bounds, configuration: GuideContent.configuration(reader: reader))
        super.init()

        webView.configuration.userContentController.add(WeakMessageHandler(self), contentWorld: .defaultClient,
                                                        name: WebMedia.handlerName)
        (webView as? GuideWebView)?.onUserEvent = { [weak self] in self?.releasePauseSuspension() }
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.pageZoom = CGFloat(Settings.shared.guideZoom)
        webView.underPageBackgroundColor = .clear
        // underPageBackgroundColor alone still leaves an opaque base. drawsBackground is private
        // (`_setDrawsBackground:`): KVC on a WebKit without it throws, so check first.
        if webView.responds(to: Selector(("_setDrawsBackground:"))) {
            webView.setValue(false, forKey: "drawsBackground")
        } else {
            Settings.log("guide: no drawsBackground switch, the page keeps WebKit's own backing")
        }
        content.autoresizingMask = [.width, .height]
        page.autoresizingMask = [.width, .height]
        content.onResize = { [weak self] in self?.layoutDocked() }
        page.onResize = { [weak self] in self?.layoutChrome() }
        buildToolbar()
        buildFindBar()
        page.addSubview(webView)
        page.addSubview(findBar)
        content.addSubview(page)
        content.addSubview(toolbar)
        layoutChrome()
        observe()
        NotificationCenter.default.addObserver(self, selector: #selector(lookupGamesChanged(_:)),
                                               name: Settings.didChange, object: nil)
        let poll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.pollMedia()
        }
        poll.tolerance = 0.5
        mediaPoll = poll
        updateToolbar()
        refreshAddress()
        if let url { load(url) }
    }

    deinit {
        mediaPoll?.invalidate()
        observations.forEach { $0.invalidate() }
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func lookupGamesChanged(_ note: Notification) {
        // The store posts from any thread; WKUserContentController is main-thread only.
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.lookupGamesChanged(note) }
            return
        }
        guard note.object as? String == LookupStore.gamesKey else { return }
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        GuideContent.addScripts(to: controller, reader: isReaderMode)
    }

    func load(_ url: URL) {
        guard hasRules else {
            // Replace the pending URL rather than wait twice, or the rule list is added twice.
            let alreadyWaiting = pendingURL != nil
            pendingURL = url
            guard !alreadyWaiting else { return }
            GuideContent.withRuleList { [weak self] list in
                guard let self else { return }
                if let list { self.webView.configuration.userContentController.add(list) }
                self.hasRules = true
                if let pending = self.pendingURL { self.pendingURL = nil; self.load(pending) }
            }
            return
        }
        Settings.log("guide: load \(url.absoluteString) reader=\(isReaderMode)")
        failedURL = nil
        webView.load(URLRequest(url: url))
    }

    func terminate() {
        mediaPoll?.invalidate()
        mediaPoll = nil
        webView.pauseAllMediaPlayback(completionHandler: nil)
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        NotificationCenter.default.removeObserver(self)
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        controller.removeAllContentRuleLists()
        controller.removeAllScriptMessageHandlers()
        webView.removeFromSuperview()
    }

    func setReaderMode(_ on: Bool) {
        isReaderMode = on
        Settings.log("guide: reader mode \(on)")
        let applied = on && !isStreamingPage
        webView.evaluateJavaScript("window.__slyterm ? window.__slyterm.setReader(\(on)) "
                                   + ": document.documentElement.classList.toggle('slyterm-reader', \(applied))")
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        GuideContent.addScripts(to: controller, reader: on)
        updateToolbar()
        if isFinding { runFind(step: 0, jump: false) }
    }

    func applyZoom() { webView.pageZoom = CGFloat(Settings.shared.guideZoom) }

    func setPlace(_ place: WebTabPlace) {
        self.place = place
        let floating = place == .floating
        let tooltip = floating ? "Put back into the SlyTerm window" : "Pop out into a floating window"
        placeButton.image = GuideToolbarView.symbol(floating ? "pip.enter" : "pip.exit", tooltip)
        placeButton.toolTip = tooltip
        closeButton.isHidden = !floating
        layoutToolbar()
    }

    func detachChrome() {
        toolbar.removeFromSuperview()
        pageView.removeFromSuperview()
    }

    func reattachChrome() {
        contentView.addSubview(pageView)
        contentView.addSubview(toolbar)
        layoutDocked()
    }

    private func layoutDocked() {
        guard toolbar.superview === contentView else { return }
        let bounds = contentView.bounds
        let pageHeight = max(0, bounds.height - GuideTab.toolbarHeight)
        pageView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: pageHeight)
        toolbar.frame = NSRect(x: 0, y: pageHeight, width: bounds.width, height: GuideTab.toolbarHeight)
        layoutChrome()
    }

    func layoutChrome() {
        let bounds = pageView.bounds
        let barHeight = isFinding ? GuideFindBar.height : 0
        findBar.frame = NSRect(x: 0, y: bounds.height - GuideFindBar.height, width: bounds.width,
                               height: GuideFindBar.height)
        webView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - barHeight))
    }

    func focusAddress() {
        takeKey(for: addressField)
        guard let window = addressField.window, window.makeFirstResponder(addressField) else { return }
        addressField.currentEditor()?.selectAll(nil)
    }

    // What the page's script cannot see (a detached `new Audio()`, a shadow root) is paused by
    // suspending the whole page, the only way WebKit resumes it later.
    func setPlaying(_ play: Bool) {
        if play, pauseSuspended {
            pauseSuspended = false
            applySuspension()
            return
        }
        let script = WebMedia.playScript(play)
        let frames = play ? mediaFrames.resumeTargets() : mediaFrames.pausePlaying()
        if !play, frames.isEmpty, playsUnseen {
            pauseSuspended = true
            applySuspension()
            return
        }
        if play, frames.isEmpty { evaluateMedia(script, in: nil); return }
        frames.forEach { evaluateMedia(script, in: $0) }
    }

    // Panic's suspension sits over play / pause's: lifting it leaves the latter in place.
    func setMediaSuspended(_ suspended: Bool) {
        panicSuspended = suspended
        applySuspension()
    }

    // WebKit's suspension is one switch, to be flipped in pairs.
    private func applySuspension() {
        let wanted = panicSuspended || pauseSuspended
        guard wanted != isSuspended else { return }
        isSuspended = wanted
        webView.setAllMediaPlaybackSuspended(wanted) { [weak self] in self?.pollMedia() }
    }

    // Suspended media refuses the page's own play(), so a click or key in the page turns the
    // suspension play / pause left into a plain pause. WebKit takes the pause, the resume and the
    // event in order.
    private func releasePauseSuspension() {
        guard pauseSuspended, !panicSuspended else { return }
        pauseSuspended = false
        webView.pauseAllMediaPlayback(completionHandler: nil)
        applySuspension()
    }

    // Panic's suspension lifted into a pause, for a tab now out of view; as above, WebKit takes
    // the pause before the resume.
    func endSuspensionPaused() {
        guard panicSuspended else { return }
        panicSuspended = false
        webView.pauseAllMediaPlayback(completionHandler: nil)
        applySuspension()
    }

    private var playsUnseen: Bool { webKitPlaying && !mediaFrames.state.isPlaying }

    // `_isPlayingAudio` is what Safari's speaker icon reads: sound is coming out, whatever makes
    // it. It is private, so only read where this WebKit has it. `requestMediaPlaybackState` is no
    // substitute: it answers "playing" for any page that merely holds a media element.
    private var isPlayingAudio: Bool {
        guard webView.responds(to: Selector(("_isPlayingAudio"))) else { return false }
        return webView.value(forKey: "_isPlayingAudio") as? Bool ?? false
    }

    private func pollMedia() {
        guard mediaPoll != nil else { return }
        let playing = isPlayingAudio
        guard playing != webKitPlaying else { return }
        webKitPlaying = playing
        applyMedia()
    }

    func setFill(_ on: Bool) {
        let script = WebMedia.fillScript(on)
        if !on { mediaFrames.filled.filter { !$0.isMainFrame }.forEach { evaluateMedia(script, in: $0) } }
        evaluateMedia(script, in: nil)
    }

    // A frame gone since its last report fails the call; nothing is left to pause or fill there.
    private func evaluateMedia(_ script: String, in frame: WKFrameInfo?) {
        webView.evaluateJavaScript(script, in: frame?.isMainFrame == false ? frame : nil, in: .defaultClient)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == WebMedia.handlerName, let report = WebMedia.report(from: message.body) else { return }
        mediaFrames.update(report, from: message.frameInfo)
        applyMedia()
        pollMedia()
    }

    private func applyMedia() {
        var state = mediaFrames.state
        if playsUnseen { state.isPlaying = true }
        guard state != media else { return }
        media = state
        host?.webTabDidChange(self)
    }

    private var isStreamingPage: Bool { WebSites.isStreaming(webView.url?.host ?? "") }

    // The failure page is about:blank; the address keeps showing what failed.
    var displayURL: URL? {
        if let url = webView.url, GuideTab.isWeb(url) { return url }
        return failedURL
    }

    private static func isWeb(_ url: URL) -> Bool { ["http", "https"].contains(url.scheme?.lowercased() ?? "") }

    // The page names itself, and the name reaches the toast, the strip's tooltip and the address.
    private var pageTitle: String {
        String((webView.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
    }

    // A field keeps its editor after its window loses the keyboard, and a floating tab's toolbar
    // and page are two windows.
    private func isEditing(_ field: NSTextField) -> Bool {
        field.currentEditor() != nil && field.window?.isKeyWindow == true
    }

    func handleCommandKey(_ event: NSEvent, shift: Bool) -> Bool {
        let editingAddress = isEditing(addressField)
        switch event.keyCode {
        case 36 where editingAddress: submitAddress(newTab: true); return true
        case 123 where !editingAddress: if webView.canGoBack { webView.goBack() }; return true
        case 124 where !editingAddress: if webView.canGoForward { webView.goForward() }; return true
        default: break
        }
        let settings = Settings.shared
        let editing = isEditingText
        let target: AnyObject? = editing ? nil : webView
        switch event.charactersIgnoringModifiers?.lowercased() ?? "" {
        case "f" where !shift: showFind(); return true
        case "e" where !shift: findSelection(); return true
        case "g" where isFinding: runFind(step: shift ? -1 : 1); return true
        case "l" where !shift: focusAddress(); return true
        case "c" where !shift:
            NSApp.sendAction(#selector(NSText.copy(_:)), to: target, from: self)
            return true
        case "a" where !shift:
            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: target, from: self)
            return true
        case "x" where !shift:
            NSApp.sendAction(#selector(NSText.cut(_:)), to: target, from: self)
            return true
        // Always consumed: passed through, ⌘V would paste into the terminal behind.
        case "v" where !shift:
            NSApp.sendAction(#selector(NSText.paste(_:)), to: target, from: self)
            return true
        case "r" where !shift: webView.reload(); return true
        case "=", "+": settings.guideZoom += 0.1; return true
        case "-": settings.guideZoom -= 0.1; return true
        case "0" where !shift: settings.guideZoom = 1; return true
        default: return false
        }
    }

    // Only while one of SlyTerm's windows has the keyboard already: a web tab never takes it
    // from the game. A floating tab's toolbar and page are two windows.
    private func takeKey(for view: NSView) {
        guard let window = view.window, !window.isKeyWindow, window.canBecomeKey,
              NSApp.keyWindow != nil else { return }
        window.makeKey()
    }

    private func buildFindBar() {
        findBar.isHidden = true
        findBar.onChange = { [weak self] _ in self?.runFind(step: 0) }
        findBar.onStep = { [weak self] step in self?.runFind(step: step) }
        findBar.onClose = { [weak self] in self?.hideFind() }
    }

    func showFind(_ query: String? = nil) {
        if !isFinding {
            isFinding = true
            findBar.isHidden = false
            layoutChrome()
        }
        if let query { findBar.query = query }
        takeKey(for: findBar)
        findBar.window?.makeFirstResponder(findBar.field)
        findBar.field.currentEditor()?.selectAll(nil)
        runFind(step: 0)
    }

    func hideFind() {
        guard isFinding else { return }
        isFinding = false
        findBar.isHidden = true
        layoutChrome()
        webView.evaluateJavaScript("window.__slyterm && window.__slyterm.findDone(true)")
        webView.window?.makeFirstResponder(webView)
    }

    private func findSelection() {
        webView.evaluateJavaScript("String(window.getSelection())") { [weak self] result, _ in
            guard let self, let text = (result as? String)?.components(separatedBy: .newlines).first?
                .trimmingCharacters(in: .whitespaces), !text.isEmpty else { return }
            self.showFind(text)
        }
    }

    private func runFind(step: Int, jump: Bool = true) {
        let query = findBar.query
        guard let data = try? JSONEncoder().encode(query), let literal = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.__slyterm ? window.__slyterm.find(\(literal), \(step), \(jump)) : null") { [weak self] result, _ in
            let found = result as? [String: Any]
            self?.findBar.show(count: found?["count"] as? Int ?? 0, index: found?["index"] as? Int ?? 0)
        }
    }

    @objc private func findFromToolbar() { showFind() }

    private func buildToolbar() {
        toolbar.autoresizingMask = [.width, .minYMargin]
        backButton = GuideToolbarView.button("chevron.left", tooltip: "Back", target: self, action: #selector(goBack))
        forwardButton = GuideToolbarView.button("chevron.right", tooltip: "Forward", target: self, action: #selector(goForward))
        findButton = GuideToolbarView.button("magnifyingglass", tooltip: "Find in page (⌘F)", target: self,
                                             action: #selector(findFromToolbar))
        readerButton = GuideToolbarView.button("doc.richtext", tooltip: "Show the full page", target: self,
                                               action: #selector(toggleReader))
        placeButton = GuideToolbarView.button("pip.exit", tooltip: "Pop out into a floating window", target: self,
                                              action: #selector(togglePlace))
        browserButton = GuideToolbarView.button("safari", tooltip: "Open in browser", target: self,
                                                action: #selector(openInBrowser))
        closeButton = GuideToolbarView.button("xmark", tooltip: "Close (⌘W)", target: self,
                                              action: #selector(closeFromToolbar))
        closeButton.isHidden = true

        addressField.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        addressField.textColor = GuideAddressField.idleColor
        addressField.isBordered = false
        addressField.isBezeled = false
        addressField.drawsBackground = false
        addressField.isEditable = true
        addressField.isSelectable = true
        addressField.focusRingType = .none
        addressField.usesSingleLineMode = true
        addressField.cell?.wraps = false
        addressField.lineBreakMode = .byTruncatingMiddle
        addressField.alignment = .center
        addressField.placeholderString = "Search or enter an address"
        addressField.appearance = NSAppearance(named: .darkAqua)
        addressField.wantsLayer = true
        addressField.layer?.cornerRadius = 4
        addressField.delegate = self
        addressField.mayEdit = { [weak self] in self?.host?.isGhost != true }
        addressField.onBegin = { [weak self] in self?.beginAddressEditing() }
        addressField.onEnd = { [weak self] in self?.endAddressEditing() }

        progress.wantsLayer = true
        progress.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.8).cgColor
        progress.frame = NSRect(x: 0, y: 0, width: 0, height: 2)
        progress.isHidden = true

        [backButton, forwardButton, addressField, findButton, readerButton, placeButton, browserButton,
         closeButton, progress].forEach { toolbar.addSubview($0) }
        toolbar.onResize = { [weak self] in self?.layoutToolbar() }
        layoutToolbar()
    }

    // Floating, the idle address shrinks to its text, so the toolbar around it is free to drag.
    private func layoutToolbar() {
        let width = toolbar.bounds.width, size: CGFloat = 20, y = (GuideTab.toolbarHeight - size) / 2
        backButton.frame = NSRect(x: 6, y: y, width: size, height: size)
        forwardButton.frame = NSRect(x: 28, y: y, width: size, height: size)
        var right = width - 4
        for button in [closeButton, browserButton, placeButton, readerButton, findButton].compactMap({ $0 })
            where !button.isHidden {
            right -= 22
            button.frame = NSRect(x: right, y: y, width: size, height: size)
        }
        let left: CGFloat = 54, available = max(0, right - 6 - left)
        var fieldWidth = available
        if place == .floating, !isEditingAddress {
            let shown = addressField.stringValue
            let text = shown.isEmpty ? addressField.placeholderString ?? "" : shown
            let font = addressField.font ?? NSFont.systemFont(ofSize: 11.5)
            fieldWidth = min(available, ceil((text as NSString).size(withAttributes: [.font: font]).width) + 12)
        }
        addressField.frame = NSRect(x: left + (available - fieldWidth) / 2, y: (GuideTab.toolbarHeight - 16) / 2,
                                    width: fieldWidth, height: 16)
        showProgress(webView.estimatedProgress, loading: webView.isLoading)
    }

    private func updateToolbar() {
        backButton.isEnabled = webView.canGoBack
        forwardButton.isEnabled = webView.canGoForward
        backButton.alphaValue = webView.canGoBack ? 1 : 0.35
        forwardButton.alphaValue = webView.canGoForward ? 1 : 0.35
        let streaming = isStreamingPage
        let readerAction = isReaderMode ? "Show the full page" : "Show reader mode"
        readerButton.image = GuideToolbarView.symbol(isReaderMode && !streaming ? "doc.richtext" : "doc.plaintext",
                                                     readerAction)
        readerButton.isEnabled = !streaming
        readerButton.alphaValue = streaming ? 0.35 : 1
        readerButton.toolTip = streaming ? "Reader mode is off on streaming sites" : readerAction
    }

    private func refreshAddress() {
        guard !isEditingAddress else { return }
        let name = pageTitle
        let url = displayURL
        addressField.stringValue = name.isEmpty ? url?.host ?? "" : name
        addressField.toolTip = url?.absoluteString
        layoutToolbar()
    }

    private func beginAddressEditing() {
        isEditingAddress = true
        addressField.stringValue = displayURL?.absoluteString ?? ""
        addressField.alignment = .left
        addressField.lineBreakMode = .byClipping
        addressField.cell?.isScrollable = true
        addressField.textColor = GuideAddressField.editingColor
        addressField.layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.1).cgColor
        layoutToolbar()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        if notification.object as? NSTextField === addressField { endAddressEditing() }
    }

    private func endAddressEditing() {
        isEditingAddress = false
        addressField.alignment = .center
        addressField.cell?.isScrollable = false
        addressField.lineBreakMode = .byTruncatingMiddle
        addressField.textColor = GuideAddressField.idleColor
        addressField.layer?.backgroundColor = nil
        refreshAddress()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === addressField else { return false }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            submitAddress(newTab: NSApp.currentEvent?.modifierFlags.contains(.command) ?? false)
        case #selector(NSResponder.cancelOperation(_:)):
            returnKeyboardToPage()
        default:
            return false
        }
        return true
    }

    private func submitAddress(newTab: Bool) {
        let typed = addressField.stringValue
        returnKeyboardToPage()
        guard let url = WebSites.address(for: typed, searchURL: Settings.shared.webSearchURL) else { return }
        if newTab, let host {
            host.openWebTab(url, select: true, focusAddress: false)
        } else {
            load(url)
        }
    }

    private func returnKeyboardToPage() {
        if let bar = toolbar.window, bar !== webView.window { bar.makeFirstResponder(nil) }
        takeKey(for: webView)
        webView.window?.makeFirstResponder(webView)
    }

    private func observe() {
        observations = [
            webView.observe(\.title, options: [.new]) { [weak self] _, _ in
                guard let self else { return }
                let name = self.pageTitle
                if !name.isEmpty { self.title = name }
                self.refreshAddress()
            },
            webView.observe(\.url, options: [.new]) { [weak self] _, _ in
                self?.refreshAddress()
                self?.updateToolbar()
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] web, _ in
                self?.showProgress(web.estimatedProgress, loading: web.isLoading)
            },
        ]
    }

    private func showProgress(_ value: Double, loading: Bool) {
        progress.isHidden = !loading || value >= 1
        progress.frame = NSRect(x: 0, y: 0, width: toolbar.bounds.width * CGFloat(value), height: 2)
    }

    @objc private func goBack() { if webView.canGoBack { webView.goBack() } }
    @objc private func goForward() { if webView.canGoForward { webView.goForward() } }
    @objc private func toggleReader() { setReaderMode(!isReaderMode) }
    @objc private func openInBrowser() {
        guard let url = displayURL else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = !Settings.shared.questOpenInBackground
        NSWorkspace.shared.open(url, configuration: configuration)
    }
    @objc private func togglePlace() {
        guard let host else { return }
        if place == .floating { host.dock(self) } else { host.float(self) }
    }
    @objc private func closeFromToolbar() { host?.closeWebTab(self) }

    private func setFavicon(_ image: NSImage?, site: String) {
        faviconSite = site
        guard image !== favicon else { return }
        favicon = image
        host?.webTabDidChange(self)
    }

    private func fetchFavicon() {
        guard let page = webView.url, GuideTab.isWeb(page), let site = page.host?.lowercased(),
              !site.isEmpty else { return }
        WebIcons.load(host: site, page: page, candidates: { [weak self] answer in
            guard let self else { answer(nil); return }
            self.webView.evaluateJavaScript(WebIcons.candidatesScript, in: nil, in: .defaultClient) {
                answer(try? $0.get())
            }
        }, completion: { [weak self] image in
            guard let self, let image, self.webView.url?.host?.lowercased() == site else { return }
            self.setFavicon(image, site: site)
        })
    }

    // WebKit gives the button as a mask of pressed buttons (middle is 4) where NSEvent numbers it
    // 2; a right click never activates a link, so either means the middle button.
    private static func opensInBackground(_ action: WKNavigationAction) -> Bool {
        action.modifierFlags.contains(.command) || action.buttonNumber == 2 || action.buttonNumber == 4
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        let scheme = url?.scheme?.lowercased() ?? ""
        // Other schemes would open another app; `about` is needed for the failure page below.
        guard ["http", "https", "about"].contains(scheme) else { decisionHandler(.cancel); return }
        if navigationAction.navigationType == .linkActivated, scheme != "about", let url, let host,
           GuideTab.opensInBackground(navigationAction) {
            host.openWebTab(url, select: false, focusAddress: false)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if let url = webView.url, GuideTab.isWeb(url) { failedURL = nil }
        mediaFrames.removeAll()
        webKitPlaying = false
        pauseSuspended = false
        applySuspension()
        applyMedia()
        pollMedia()
        let site = webView.url?.host?.lowercased() ?? ""
        if site != faviconSite { setFavicon(WebIcons.cached(site), site: site) }
        updateToolbar()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        updateToolbar()
        showProgress(1, loading: false)
        if isFinding { runFind(step: 0, jump: false) }
        fetchFavicon()
        onLoadEnd?(nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    private func failed(_ error: Error) {
        updateToolbar()
        showProgress(1, loading: false)
        onLoadEnd?(error)
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        Settings.log("guide: load failed: \(error.localizedDescription)")
        // Kept for "Open in browser", which must never hand NSWorkspace another scheme.
        let failing = (error as NSError).userInfo[NSURLErrorFailingURLErrorKey] as? URL ?? displayURL
        failedURL = failing.flatMap { GuideTab.isWeb($0) ? $0 : nil }
        let message = error.localizedDescription
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
        // The user script still injects and inverts this page; the later rule below undoes it.
        webView.loadHTMLString("""
        <!doctype html><meta charset="utf-8"><meta name="color-scheme" content="dark">
        <style>
          html.slyterm-reader { filter: none !important }
          body { background: transparent; color: #e4e4ea; font: 14px/1.5 -apple-system, system-ui, sans-serif;
                 margin: 0; padding: 24px 16px }
          p { color: #9a9aa4 }
        </style>
        <h1 style="font-size:18px">The page did not load</h1>
        <p>\(message)</p>
        """, baseURL: nil)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = navigationAction.request.url, GuideTab.isWeb(url) else { return nil }
        // Each pop-up needs a click, but a page can still answer one click with a burst of them.
        let now = Date()
        popups = popups.filter { now.timeIntervalSince($0) < 5 }
        guard popups.count < 3 else {
            Settings.log("guide: pop-up ignored, 3 tabs opened in 5 s: \(url.absoluteString)")
            return nil
        }
        popups.append(now)
        if let host {
            host.openWebTab(url, select: !GuideTab.opensInBackground(navigationAction), focusAddress: false)
        } else {
            webView.load(URLRequest(url: url))
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        Settings.log("guide: alert swallowed: \(message)")
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        completionHandler(false)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        completionHandler(nil)
    }
}

// The user content controller retains its handlers, and the tab owns the controller's web view.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

private extension NSImage {
    func with(_ rep: NSBitmapImageRep) -> NSImage { addRepresentation(rep); return self }
}

private final class GuideWebView: WKWebView {
    var onUserEvent: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onUserEvent?()
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        onUserEvent?()
        super.keyDown(with: event)
    }
}

// Lays its subviews out by hand: it may be sized from zero by whichever window holds it, which
// autoresizing masks get wrong.
private final class GuideLayoutView: NSView {
    var onResize: (() -> Void)?

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        if let onResize { onResize() } else { super.resizeSubviews(withOldSize: oldSize) }
    }
}

private final class GuideAddressField: NSTextField {
    static let idleColor = NSColor(calibratedWhite: 1, alpha: 0.75)
    static let editingColor = NSColor(calibratedWhite: 1, alpha: 0.95)

    var mayEdit: () -> Bool = { true }
    var onBegin: (() -> Void)?
    var onEnd: (() -> Void)?
    var isEditing: Bool { currentEditor() != nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // AppKit hands a window's first key view the first responder when the window is first ordered
    // in, key or not: the floating toolbar's panel would open with this field stuck mid-edit.
    override func becomeFirstResponder() -> Bool {
        guard mayEdit(), window?.isKeyWindow == true else { return false }
        onBegin?()
        let became = super.becomeFirstResponder()
        guard became else { onEnd?(); return false }
        // The whole address ends up selected, as in a browser. Async, so it comes after the click
        // that placed the caret: a panel becoming key starts the edit before its click lands.
        DispatchQueue.main.async { [weak self] in self?.currentEditor()?.selectAll(nil) }
        return true
    }
}

class GuideToolbarView: NSView {
    static let idleTint = NSColor(calibratedWhite: 1, alpha: 0.7)
    static let hoverTint = NSColor(calibratedWhite: 1, alpha: 0.95)
    var onResize: (() -> Void)?
    private var trackingArea: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = GuideTab.toolbarColor.cgColor
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    static func symbol(_ name: String, _ description: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: description)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
    }

    static func button(_ symbol: String, tooltip: String, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(frame: .zero)
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.image = GuideToolbarView.symbol(symbol, tooltip)
        button.contentTintColor = idleTint
        button.toolTip = tooltip
        button.target = target
        button.action = action
        return button
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        if let onResize { onResize() } else { super.resizeSubviews(withOldSize: oldSize) }
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        for case let button as NSButton in subviews {
            button.contentTintColor = button.frame.contains(point) ? GuideToolbarView.hoverTint : GuideToolbarView.idleTint
        }
    }

    override func mouseExited(with event: NSEvent) {
        for case let button as NSButton in subviews { button.contentTintColor = GuideToolbarView.idleTint }
    }
}

enum GuideSnapshotCLI {
    static func run(_ args: [String]) -> Bool {
        guard args.count >= 4, args[1] == "--guide-snapshot", let url = URL(string: args[2]) else { return false }
        Settings.echo = true
        NSApp.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: args[3])
        let reader = !args.contains("--full")
        let fill = args.contains("--fill")
        let width = number(args, "--width") ?? 600
        let height = number(args, "--height") ?? 900
        let scroll = number(args, "--scroll") ?? 0
        let script = string(args, "--eval")
        let query = string(args, "--find")

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height + GuideTab.toolbarHeight),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let tab = GuideTab(frame: window.contentView!.bounds, url: nil, reader: reader)
        window.contentView?.addSubview(tab.contentView)
        tab.webView.configuration.userContentController.addUserScript(
            WKUserScript(source: muteSource, injectionTime: .atDocumentStart, forMainFrameOnly: false,
                         in: .defaultClient))

        var done = false
        let started = Date()
        tab.onLoadEnd = { error in
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            if let error { print("load failed after \(ms) ms: \(error.localizedDescription)") }
            print("loaded in \(ms) ms")
            // Images arrive after didFinish.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if let query { tab.showFind(query) }
                tab.webView.evaluateJavaScript("window.scrollTo(0, \(Int(scroll)))") { _, _ in
                    // WebKit decodes images as they scroll into view: no snapshot right away.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        tab.webView.evaluateJavaScript(script ?? "0") { _, error in
                            if let error, script != nil { print("eval failed: \(error.localizedDescription)") }
                            DispatchQueue.main.asyncAfter(deadline: .now() + (script == nil ? 0 : 2.0)) {
                                fillIfAsked(tab, fill) {
                                    media(tab) {
                                        report(tab.webView) {
                                            write(tab, to: output, reader: reader) { done = true }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        tab.load(url)

        let deadline = Date().addingTimeInterval(60)
        while !done, Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        if !done { print("timed out") }
        return true
    }

    // A video that starts on its own would otherwise play through the speakers.
    private static let muteSource = """
    (function () {
      function mute(event) { var m = event.target; if (m && "muted" in m && !m.muted) m.muted = true; }
      ["loadstart", "play", "playing", "volumechange"].forEach(function (type) {
        document.addEventListener(type, mute, true);
      });
    })();
    """

    private static func string(_ args: [String], _ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), args.indices.contains(i + 1) else { return nil }
        return args[i + 1]
    }

    private static func number(_ args: [String], _ flag: String) -> CGFloat? {
        guard let i = args.firstIndex(of: flag), args.indices.contains(i + 1), let value = Double(args[i + 1]) else { return nil }
        return CGFloat(value)
    }

    private static func fillIfAsked(_ tab: GuideTab, _ fill: Bool, then: @escaping () -> Void) {
        guard fill else { then(); return }
        tab.webView.evaluateJavaScript(WebMedia.fillScript(true), in: nil, in: .defaultClient) { result in
            if case .success(let value) = result, value as? Bool == true {} else { print("fill: nothing to fill") }
            // The player lays itself out again on the fullscreenchange and resize it is sent.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: then)
        }
    }

    private static func media(_ tab: GuideTab, then: @escaping () -> Void) {
        tab.webView.evaluateJavaScript(WebMedia.reportScript, in: nil, in: .defaultClient) { result in
            defer { then() }
            guard case .success(let value) = result, let info = value as? [String: Any] else {
                print("media: no controller in the page")
                return
            }
            func box(_ key: String) -> String {
                guard let v = info[key] as? [NSNumber], v.count == 4 else { return "none" }
                return "\(v[2])x\(v[3]) at \(v[0]),\(v[1])"
            }
            func flag(_ key: String) -> String { (info[key] as? Bool).map { "\($0)" } ?? "?" }
            let viewport = (info["viewport"] as? [NSNumber])?.map(\.stringValue).joined(separator: "x") ?? "?"
            let aspect = (info["aspect"] as? Double).map { String(format: "%.2f", $0) } ?? "?"
            let kind = info["kind"] as? String ?? "?"
            let state = tab.media
            print("media: \(kind == "none" ? kind : "\(kind) \(box("media"))"), playing=\(flag("playing")) "
                  + "busy=\(flag("busy")) video=\(flag("video")) aspect=\(aspect) filled=\(flag("filled")) "
                  + "target=\(info["target"] ?? "?") · tab: playing=\(state.isPlaying) video=\(state.hasVideo) "
                  + "aspect=\(state.aspect.map { String(format: "%.2f", $0) } ?? "none") filled=\(state.isFilled)")
            if info["filled"] as? Bool == true {
                print("fill: \(info["target"] ?? "?") \(box("targetBox")) in a \(viewport) viewport")
            }
        }
    }

    private static func report(_ webView: WKWebView, then: @escaping () -> Void) {
        webView.evaluateJavaScript("""
        (() => {
          const r = performance.getEntriesByType('resource');
          return { requests: r.length, kb: Math.round(r.reduce((a, e) => a + (e.transferSize || 0), 0) / 1024),
                   width: document.documentElement.scrollWidth, height: document.documentElement.scrollHeight,
                   scrollY: Math.round(window.scrollY), images: document.images.length, title: document.title };
        })()
        """) { value, _ in
            print("page: \(value.map { "\($0)" } ?? "unreadable")")
            then()
        }
    }

    // cacheDisplay skips layer backgrounds offscreen, so the chrome's backgrounds are filled here.
    private static func write(_ tab: GuideTab, to output: URL, reader: Bool, then: @escaping () -> Void) {
        let webView = tab.webView
        let configuration = WKSnapshotConfiguration()
        configuration.rect = webView.bounds
        webView.takeSnapshot(with: configuration) { image, error in
            defer { then() }
            guard let image else { print("snapshot failed: \(error?.localizedDescription ?? "?")"); return }
            let whole = tab.isFinding
            let size = whole ? tab.contentView.bounds.size : image.size
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            if reader {
                TerminalTab.backgroundColor.setFill()
                NSRect(origin: .zero, size: size).fill()
            }
            image.draw(in: NSRect(origin: .zero, size: image.size))
            if whole {
                let chrome = [tab.toolbar] + tab.pageView.subviews.filter { !($0 is WKWebView) }
                for view in chrome where !view.isHidden {
                    let frame = view.convert(view.bounds, to: tab.contentView)
                    GuideTab.toolbarColor.setFill()
                    frame.fill()
                    guard let drawn = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                    view.cacheDisplay(in: view.bounds, to: drawn)
                    NSImage(size: view.bounds.size).with(drawn).draw(in: frame)
                }
            }
            NSGraphicsContext.restoreGraphicsState()
            guard let png = rep.representation(using: .png, properties: [:]) else { return }
            do {
                try png.write(to: output)
                print("wrote \(output.path) (\(Int(size.width))x\(Int(size.height)))")
            } catch {
                print("cannot write \(output.path): \(error.localizedDescription)")
            }
        }
    }
}
