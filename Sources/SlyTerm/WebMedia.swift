import AppKit
import ImageIO
import WebKit

enum WebMedia {
    static let handlerName = "slytermMedia"

    struct Report: Equatable {
        var token: String
        var playing: Bool
        var busy: Bool
        var video: Bool
        var aspect: CGFloat?
        var filled: Bool
        var gone: Bool
    }

    // Posted by the page's own frames: anything that is not the expected shape is dropped.
    static func report(from body: Any) -> Report? {
        guard let object = body as? [String: Any],
              let token = object["token"] as? String, !token.isEmpty, token.count <= 64,
              let playing = object["playing"] as? Bool, let busy = object["busy"] as? Bool,
              let video = object["video"] as? Bool, let filled = object["filled"] as? Bool else { return nil }
        var aspect: CGFloat?
        if let value = object["aspect"] as? Double, value.isFinite, value > 0 {
            aspect = CGFloat(min(4, max(0.5, value)))
        }
        return Report(token: token, playing: playing, busy: busy, video: video, aspect: aspect,
                      filled: filled, gone: object["gone"] as? Bool ?? false)
    }

    static func fillScript(_ on: Bool) -> String {
        "window.__slytermMedia ? window.__slytermMedia.fill(\(on)) : false"
    }

    static func playScript(_ on: Bool) -> String {
        "window.__slytermMedia ? window.__slytermMedia.play(\(on)) : false"
    }

    static let reportScript = "window.__slytermMedia ? window.__slytermMedia.report() : false"

    static func userScripts() -> [WKUserScript] {
        [WKUserScript(source: shimSource, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page),
         WKUserScript(source: controllerSource, injectionTime: .atDocumentStart, forMainFrameOnly: false,
                      in: .defaultClient)]
    }

    // WebKit's element fullscreen is off (it opens a Space of its own, away from the game), so
    // the page sees this instead: a request asks the controller below to fill the web view.
    private static let shimSource = """
    (function () {
      try {
        var FILL = "[data-slyterm-fill]", Custom = window.CustomEvent, Waiter = window.Promise;
        function define(proto, name, descriptor) {
          try { descriptor.configurable = true; Object.defineProperty(proto, name, descriptor); } catch (e) {}
        }
        function method(proto, name, fn) { define(proto, name, { value: fn, writable: true }); }
        function getter(proto, name, fn) { define(proto, name, { get: fn }); }
        function current(doc) {
          try { return (doc && doc.querySelector ? doc : document).querySelector(FILL); } catch (e) { return null; }
        }
        function allowed() {
          var activation = navigator.userActivation;
          return !activation || activation.isActive;
        }
        function enter(el) {
          if (!allowed()) return false;
          el.dispatchEvent(new Custom("slyterm-fullscreen-enter", { bubbles: true, composed: true }));
          return true;
        }
        function leave() {
          try { document.dispatchEvent(new Custom("slyterm-fullscreen-exit")); } catch (e) {}
        }
        function later(resolve) { setTimeout(function () { resolve(); }, 0); }
        function request() {
          var el = this;
          return new Waiter(function (resolve, reject) {
            try { if (enter(el)) later(resolve); else reject(new TypeError("Fullscreen request denied")); }
            catch (e) { reject(e); }
          });
        }
        function legacyRequest() { try { enter(this); } catch (e) {} }
        function exit() { leave(); return new Waiter(later); }
        function legacyExit() { leave(); }
        var elements = Element.prototype, docs = Document.prototype, videos = HTMLVideoElement.prototype;
        method(elements, "requestFullscreen", request);
        method(elements, "webkitRequestFullscreen", legacyRequest);
        method(elements, "webkitRequestFullScreen", legacyRequest);
        method(docs, "exitFullscreen", exit);
        method(docs, "webkitExitFullscreen", legacyExit);
        method(docs, "webkitCancelFullScreen", legacyExit);
        ["fullscreenElement", "webkitFullscreenElement", "webkitCurrentFullScreenElement"].forEach(function (name) {
          getter(docs, name, function () { return current(this); });
        });
        ["fullscreenEnabled", "webkitFullscreenEnabled"].forEach(function (name) {
          getter(docs, name, function () { return true; });
        });
        ["fullscreen", "webkitIsFullScreen"].forEach(function (name) {
          getter(docs, name, function () { return !!current(this); });
        });
        method(videos, "webkitEnterFullscreen", legacyRequest);
        method(videos, "webkitEnterFullScreen", legacyRequest);
        method(videos, "webkitExitFullscreen", legacyExit);
        method(videos, "webkitExitFullScreen", legacyExit);
        getter(videos, "webkitSupportsFullscreen", function () { return true; });
        getter(videos, "webkitDisplayingFullscreen", function () {
          try { return !!this.closest(FILL); } catch (e) { return false; }
        });
        // Players pick the event to listen for by testing `"onfullscreenchange" in document`.
        var own = new WeakMap();
        var types = ["fullscreenchange", "fullscreenerror", "webkitfullscreenchange", "webkitfullscreenerror"];
        types.forEach(function (type) {
          [docs, elements].forEach(function (proto) {
            define(proto, "on" + type, {
              get: function () { var set = own.get(this); return (set && set[type]) || null; },
              set: function (fn) {
                try {
                  var set = own.get(this) || {};
                  own.set(this, set);
                  if (set[type]) this.removeEventListener(type, set[type]);
                  set[type] = typeof fn === "function" ? fn : null;
                  if (set[type]) this.addEventListener(type, set[type]);
                } catch (e) {}
              }
            });
          });
        });
      } catch (e) {}
    })();
    """

    // Ancestors lose what would make them the containing block of a fixed element, clip it, or
    // make a stacking context the page could paint over; the reader's inversion is lifted while a
    // player fills. Attributes, not classes: some players' frameworks rewrite `className`.
    private static let fillStylesheet = """
    html[data-slyterm-fill-root], html[data-slyterm-fill-root] body { overflow: hidden !important; }
    html[data-slyterm-fill-root] { scrollbar-width: none !important; filter: none !important; }
    html[data-slyterm-fill-root]::-webkit-scrollbar { display: none !important; }
    html[data-slyterm-fill-root].slyterm-reader :is(img, video, iframe, canvas, svg) { filter: none !important; }
    [data-slyterm-fill-ancestor] {
      transform: none !important; translate: none !important; rotate: none !important; scale: none !important;
      filter: none !important; perspective: none !important; contain: none !important;
      content-visibility: visible !important; will-change: auto !important; backdrop-filter: none !important;
      -webkit-backdrop-filter: none !important; clip-path: none !important; -webkit-clip-path: none !important;
      mask: none !important; -webkit-mask: none !important; opacity: 1 !important;
      mix-blend-mode: normal !important; isolation: auto !important; z-index: auto !important;
    }
    [data-slyterm-filled][data-slyterm-filled] {
      position: fixed !important; inset: 0 !important; width: 100vw !important; height: 100vh !important;
      max-width: none !important; max-height: none !important; min-width: 0 !important; min-height: 0 !important;
      margin: 0 !important; transform: none !important; translate: none !important; rotate: none !important;
      scale: none !important; border-radius: 0 !important; box-sizing: border-box !important;
      z-index: 2147483647 !important; background: #000 !important;
    }
    [data-slyterm-fill-path] {
      width: 100% !important; height: 100% !important; max-width: none !important; max-height: none !important;
      min-width: 0 !important; min-height: 0 !important; top: 0 !important; left: 0 !important;
      margin: 0 !important; transform: none !important; translate: none !important; rotate: none !important;
      scale: none !important; border-radius: 0 !important;
    }
    [data-slyterm-filled] video, video[data-slyterm-filled] { object-fit: contain !important; }
    """

    private static var controllerSource: String {
        """
        (function () {
          if (window.__slytermMedia || !document.documentElement) return;
          var root = document.documentElement, isTop = window === window.top;
          var token = Math.random().toString(36).slice(2) + Date.now().toString(36);
          var handlers = window.webkit && window.webkit.messageHandlers;
          var handler = handlers && handlers.\(handlerName);
          var FILL = "data-slyterm-fill", css = \(literal(fillStylesheet));
          var filled = null, claimed = null, touched = [], sheets = [], paused = [], last = "", timer = 0;
          var watcher = null, quiet = false;

          function up(node) { return node.parentElement || (node.parentNode && node.parentNode.host) || null; }
          function rendered(el) {
            var r = el.getBoundingClientRect();
            if (r.width < 1 || r.height < 1) return null;
            return getComputedStyle(el).visibility === "hidden" ? null : r;
          }
          function moving(m) { return !m.paused && !m.ended; }
          function audible(m) { return !m.muted && m.volume > 0; }
          function shown(m) {
            var r = m.tagName === "VIDEO" && rendered(m);
            if (!r) return false;
            return Math.min(r.right, window.innerWidth) - Math.max(r.left, 0) >= 200 &&
                   Math.min(r.bottom, window.innerHeight) - Math.max(r.top, 0) >= 112;
          }
          // A muted loop, or one out of sight, is decoration rather than something being watched.
          function playing(m) { return moving(m) && (audible(m) || shown(m)); }

          function mainMedia() {
            var best = null, area = 0, live = false, list = document.getElementsByTagName("video"), i, r;
            for (i = 0; i < list.length && i < 64; i++) {
              if (!(r = rendered(list[i]))) continue;
              var a = r.width * r.height, p = playing(list[i]);
              if ((p && !live) || (p === live && a > area)) { best = list[i]; area = a; live = p; }
            }
            if (best || !isTop) return best;
            list = document.getElementsByTagName("iframe");
            for (i = 0; i < list.length && i < 64; i++) {
              r = rendered(list[i]);
              if (r && r.width >= 200 && r.height >= 112 && r.width * r.height > area) {
                best = list[i];
                area = r.width * r.height;
              }
            }
            return best;
          }

          // A wrapper of zero height around an absolutely placed video is climbed through.
          function container(el) {
            var r = el.getBoundingClientRect(), node = el, best = el, parent;
            while ((parent = up(node)) && parent !== document.body && parent !== root) {
              var p = parent.getBoundingClientRect(), empty = p.width < 1 || p.height < 1;
              if (!empty && (Math.abs(p.left - r.left) > 4 || Math.abs(p.top - r.top) > 4 ||
                             Math.abs(p.right - r.right) > 4 || Math.abs(p.bottom - r.bottom) > 4)) break;
              node = parent;
              if (!empty) best = parent;
            }
            return best;
          }

          function between(from, to) {
            var list = [];
            for (var node = from; node && node !== to; node = up(node)) list.push(node);
            return node ? list : [];
          }

          function tag(node, name) {
            node.setAttribute(name, "");
            touched.push([node, name]);
          }

          // `asked` is what the page is told is fullscreen, `target` what fills the view. They differ
          // when the page asks for a video (its player fills) or for itself (its video's player does).
          function mark(target, path, asked) {
            asked.setAttribute(FILL, "");
            if (target === root || target === document.body) return;
            var scopes = [];
            tag(target, "data-slyterm-filled");
            path.forEach(function (node) { tag(node, "data-slyterm-fill-path"); });
            for (var node = up(target); node && node !== root; node = up(node)) {
              tag(node, "data-slyterm-fill-ancestor");
            }
            tag(root, "data-slyterm-fill-root");
            touched.forEach(function (entry) {
              var scope = entry[0].getRootNode();
              if (scopes.indexOf(scope) < 0) scopes.push(scope);
            });
            scopes.forEach(function (scope) {
              var style = document.createElement("style");
              style.textContent = css;
              (scope === document ? document.head || root : scope).appendChild(style);
              sheets.push(style);
            });
            // A site that moves on without leaving fullscreen (YouTube's in-page navigation) hides
            // the player instead, which would leave the page filled with nothing.
            if (window.ResizeObserver) {
              watcher = new ResizeObserver(function () {
                var r = filled && filled.getBoundingClientRect();
                if (r && r.width < 1 && r.height < 1) request(false);
              });
              watcher.observe(target);
            }
          }

          function unmark() {
            claimed.removeAttribute(FILL);
            touched.forEach(function (entry) { entry[0].removeAttribute(entry[1]); });
            sheets.forEach(function (style) { style.remove(); });
            if (watcher) watcher.disconnect();
            watcher = null;
            touched = [];
            sheets = [];
          }

          // After the call that asked, resize first, as a browser does: sites check their own state
          // when the change arrives.
          function announce(el) {
            setTimeout(function () {
              window.dispatchEvent(new Event("resize"));
              var at = el.isConnected ? el : document;
              ["fullscreenchange", "webkitfullscreenchange"].forEach(function (type) {
                at.dispatchEvent(new Event(type, { bubbles: true, composed: true }));
              });
            }, 0);
          }

          // Our own fill also stretches what lies between the container and the media, which all
          // had the media's box; a fill the site asked for is laid out by the site.
          function fill(on, target, asked, path) {
            if (on) {
              if (!target && filled) return true;
              if (!target) {
                var media = mainMedia();
                if (!media) return false;
                target = container(media);
                path = between(media, target);
              }
              asked = asked || target;
              if (target === filled && asked === claimed) return true;
              if (filled) unmark();
              filled = target;
              claimed = asked;
              mark(target, path || [], asked);
              announce(asked);
            } else {
              if (!filled) return false;
              var was = claimed;
              unmark();
              filled = claimed = null;
              announce(was);
            }
            send();
            return true;
          }

          function play(on) {
            var list, i;
            if (!on) {
              var now = [];
              list = document.querySelectorAll("video, audio");
              for (i = 0; i < list.length; i++) {
                if (!playing(list[i])) continue;
                try { list[i].pause(); now.push(list[i]); } catch (e) {}
              }
              // A second pause with nothing left playing keeps what the first one paused.
              if (now.length) paused = now;
              return now.length > 0;
            }
            list = paused.filter(function (m) { return m.isConnected; });
            paused = [];
            if (!list.length) {
              var media = mainMedia();
              if (media && media.tagName === "VIDEO") list = [media];
              else list = Array.prototype.slice.call(document.getElementsByTagName("audio"), 0, 1);
            }
            list.forEach(function (m) {
              try { var p = m.play(); if (p && p.catch) p.catch(function () {}); } catch (e) {}
            });
            return list.length > 0;
          }

          function state() {
            if (filled && !(filled.isConnected && claimed.isConnected)) { unmark(); filled = claimed = null; }
            var list = document.querySelectorAll("video, audio"), live = false, busy = false;
            quiet = false;
            for (var i = 0; i < list.length; i++) {
              if (!moving(list[i])) continue;
              busy = true;
              if (audible(list[i])) { live = true; continue; }
              quiet = true;
              if (!live) live = shown(list[i]);
            }
            var media = mainMedia();
            var video = !!(media && media.tagName === "VIDEO" && media.videoWidth > 0 && media.videoHeight > 0);
            return { token: token, playing: live, busy: busy, video: video, filled: !!filled, gone: false,
                     aspect: video ? media.videoWidth / media.videoHeight : 0 };
          }

          function send(gone) {
            clearTimeout(timer);
            timer = 0;
            if (!handler) return;
            var now = state();
            now.gone = !!gone;
            var key = JSON.stringify(now);
            if (key === last) return;
            last = key;
            try { handler.postMessage(now); } catch (e) {}
          }
          function schedule() { if (!timer) timer = setTimeout(send, 120); }

          ["play", "playing", "pause", "ended", "emptied", "loadedmetadata", "volumechange", "resize"]
            .forEach(function (type) { document.addEventListener(type, schedule, true); });
          // Whether a silent video counts depends on it being in view.
          function moved() { if (quiet) schedule(); }
          document.addEventListener("scroll", moved, { capture: true, passive: true });
          window.addEventListener("resize", moved);
          window.addEventListener("pagehide", function () { send(true); });
          window.addEventListener("pageshow", function (event) { if (event.persisted) { last = ""; schedule(); } });

          // Real fullscreen gives the page no Esc either.
          window.addEventListener("keydown", function (event) {
            if (event.key !== "Escape" || !filled) return;
            event.preventDefault();
            event.stopImmediatePropagation();
            request(false);
          }, true);

          // As the Fullscreen API does, a request counts only right after a click or a key; WebKit
          // hands that activation to the parent frames too.
          function activated() {
            var activation = navigator.userActivation;
            return !activation || activation.isActive;
          }

          // A page asking for itself still paints its own bars over its player: a real browser's
          // top layer, or the page's own :fullscreen rules, would have hidden them.
          function playerVideo() {
            var media = mainMedia(), r = media && media.getBoundingClientRect();
            return media && media.tagName === "VIDEO" && r.width >= 200 && r.height >= 112 ? media : null;
          }

          // A frame filling itself fills only its own box, so its parent fills the frame element,
          // which the parent page then sees as fullscreen.
          function request(on, el) {
            var was = claimed;
            if (on) {
              var media = el.tagName === "VIDEO" ? el : el === root || el === document.body ? playerVideo() : null;
              var target = media ? container(media) : el;
              fill(true, target, el, media ? between(media, target) : []);
            } else {
              fill(false);
            }
            if (!isTop && (on || was)) {
              try { window.parent.postMessage({ slytermFrameFill: on }, "*"); } catch (e) {}
            }
            if (!on && was && was.tagName === "IFRAME" && was.contentWindow) {
              try { was.contentWindow.postMessage({ slytermFrameExit: true }, "*"); } catch (e) {}
            }
          }

          document.addEventListener("slyterm-fullscreen-enter", function (event) {
            var el = event.composedPath()[0];
            if (el && el.nodeType === 1 && activated()) request(true, el);
          }, true);
          document.addEventListener("slyterm-fullscreen-exit", function () { request(false); }, true);

          // As in a browser, a frame goes fullscreen only when its element allows it.
          function allowsFullscreen(frame) {
            if (frame.hasAttribute("allowfullscreen") || frame.hasAttribute("webkitallowfullscreen")) {
              return true;
            }
            return String(frame.getAttribute("allow") || "").toLowerCase().split(";").some(function (rule) {
              var words = rule.trim().split(/\\s+/);
              return words[0] === "fullscreen" && words.indexOf("'none'") < 0;
            });
          }

          window.addEventListener("message", function (event) {
            var data = event.data, frame = null;
            if (!data || typeof data !== "object") return;
            if (data.slytermFrameExit === true && event.source === window.parent) { request(false); return; }
            if (typeof data.slytermFrameFill !== "boolean") return;
            var frames = document.getElementsByTagName("iframe");
            for (var i = 0; i < frames.length && !frame; i++) {
              if (frames[i].contentWindow === event.source) frame = frames[i];
            }
            if (!frame) return;
            if (!data.slytermFrameFill) {
              if (claimed === frame) request(false);
            } else if (activated() && allowsFullscreen(frame)) {
              request(true, frame);
            } else {
              try { event.source.postMessage({ slytermFrameExit: true }, "*"); } catch (e) {}
            }
          });

          function describe(el) {
            if (!el) return "none";
            var text = el.tagName.toLowerCase() + (el.id ? "#" + el.id : "");
            if (typeof el.className === "string" && el.className.trim()) {
              text += "." + el.className.trim().split(/\\s+/).slice(0, 3).join(".");
            }
            return text;
          }
          function box(el) {
            if (!el) return null;
            var r = el.getBoundingClientRect();
            return [Math.round(r.left), Math.round(r.top), Math.round(r.width), Math.round(r.height)];
          }

          window.__slytermMedia = {
            fill: function (on) { return fill(!!on); },
            play: function (on) { return play(!!on); },
            report: function () {
              var media = mainMedia(), now = state();
              send();
              return { kind: media ? media.tagName.toLowerCase() : "none", media: box(media),
                       target: describe(filled || (media && container(media))), targetBox: box(filled),
                       viewport: [window.innerWidth, window.innerHeight], playing: now.playing,
                       busy: now.busy, video: now.video, aspect: now.aspect, filled: now.filled };
            }
          };
        })();
        """
    }

    // U+2028/U+2029 end a JavaScript string; `<` is escaped so no value can close a <script> tag.
    private static func literal(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
              let text = String(data: data, encoding: .utf8) else { return "\"\"" }
        return text.replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
            .replacingOccurrences(of: "<", with: "\\u003c")
    }
}

// What each frame of one page last said about its media, merged into the tab's WebMediaState.
struct WebMediaFrames {
    struct Frame {
        var info: WKFrameInfo
        var report: WebMedia.Report
        var order: Int
    }

    static let limit = 16

    private(set) var frames: [String: Frame] = [:]
    private var order = 0
    private var lastPlaying: String?
    private var paused: Set<String> = []

    mutating func update(_ report: WebMedia.Report, from info: WKFrameInfo) {
        guard !report.gone else {
            frames[report.token] = nil
            return
        }
        if frames[report.token] == nil, frames.count >= WebMediaFrames.limit {
            let quiet = frames.filter { !$0.value.report.playing }
            let pool = quiet.isEmpty ? frames : quiet
            if let oldest = pool.min(by: { $0.value.order < $1.value.order }) { frames[oldest.key] = nil }
        }
        order += 1
        frames[report.token] = Frame(info: info, report: report, order: order)
        if report.playing { lastPlaying = report.token }
    }

    mutating func removeAll() {
        frames.removeAll()
        lastPlaying = nil
        paused.removeAll()
    }

    var state: WebMediaState {
        let all = Array(frames.values)
        let playing = all.filter { $0.report.playing }
        let source = playing.first { $0.info.isMainFrame } ?? playing.max { $0.order < $1.order }
            ?? all.first { $0.info.isMainFrame }
        var state = WebMediaState()
        state.isPlaying = !playing.isEmpty
        state.hasVideo = source?.report.video ?? false
        state.aspect = state.hasVideo ? source?.report.aspect : nil
        state.isFilled = all.contains { $0.report.filled }
        return state
    }

    var filled: [WKFrameInfo] { frames.values.filter { $0.report.filled }.map(\.info) }

    mutating func pausePlaying() -> [WKFrameInfo] {
        let playing = frames.filter { $0.value.report.playing }
        paused = Set(playing.keys)
        return playing.values.map(\.info)
    }

    // The frames setPlaying(false) paused, else the one that played last; empty means the main frame.
    mutating func resumeTargets() -> [WKFrameInfo] {
        defer { paused.removeAll() }
        let again = paused.compactMap { frames[$0]?.info }
        if !again.isEmpty { return again }
        return lastPlaying.flatMap { frames[$0] }.map { [$0.info] } ?? []
    }
}

// One favicon per host per launch, kept in memory. The cache and its waiters are main-thread only.
enum WebIcons {
    private enum Entry {
        case loading([(NSImage?) -> Void])
        case done(NSImage?)
    }

    private static var entries: [String: Entry] = [:]
    private static let maxBytes = 256 * 1024
    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.slyterm.favicons"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    static let candidatesScript = """
    (function () {
      var out = [], links = document.querySelectorAll("link[rel]");
      for (var i = 0; i < links.length && out.length < 32; i++) {
        var link = links[i], rel = (link.getAttribute("rel") || "").toLowerCase();
        if (!/(^|\\s)(icon|apple-touch-icon|apple-touch-icon-precomposed)(\\s|$)/.test(rel)) continue;
        out.push({ href: String(link.href || "").slice(0, 2048),
                   sizes: String(link.getAttribute("sizes") || "").slice(0, 64),
                   type: String(link.getAttribute("type") || "").slice(0, 64) });
      }
      return out;
    })()
    """

    static func cached(_ host: String) -> NSImage? {
        if case .done(let image)? = entries[host] { return image }
        return nil
    }

    // `candidates` is asked for the page's declared icons only when the host has never been tried.
    static func load(host: String, page: URL, candidates: (@escaping (Any?) -> Void) -> Void,
                     completion: @escaping (NSImage?) -> Void) {
        switch entries[host] {
        case .done(let image)?:
            completion(image)
        case .loading(let waiting)?:
            entries[host] = .loading(waiting + [completion])
        case nil:
            entries[host] = .loading([completion])
            candidates { found in
                guard let url = choose(found, page: page) else { finish(host, nil); return }
                download(url) { image in DispatchQueue.main.async { finish(host, image) } }
            }
        }
    }

    private static func finish(_ host: String, _ image: NSImage?) {
        guard case .loading(let waiting)? = entries[host] else { return }
        entries[host] = .done(image)
        waiting.forEach { $0(image) }
    }

    // Bitmaps first (SVG does not decode here), the smallest of at least 32 px, then unsized ones,
    // then the largest smaller one; the origin's /favicon.ico when the page declares none.
    static func choose(_ found: Any?, page: URL) -> URL? {
        var best: (rank: (Int, Int, Int), url: URL)?
        for item in (found as? [Any] ?? []).prefix(32) {
            guard let entry = item as? [String: Any], let href = entry["href"] as? String, href.count <= 2048,
                  let url = URL(string: href), isWeb(url) else { continue }
            let type = (entry["type"] as? String ?? "").lowercased()
            let path = url.path.lowercased()
            if type.contains("svg") || path.hasSuffix(".svg") { continue }
            let bitmap = type.contains("png") || type.contains("icon")
                || path.hasSuffix(".png") || path.hasSuffix(".ico")
            let size = (entry["sizes"] as? String ?? "").lowercased().split(separator: " ").compactMap { token in
                token.split(separator: "x").first.flatMap { Int($0) }
            }.max() ?? 0
            let sizeRank = size >= 32 ? (0, size) : size == 0 ? (1, 0) : (2, -size)
            let rank = (bitmap ? 0 : 1, sizeRank.0, sizeRank.1)
            if best == nil || rank < best!.rank { best = (rank, url) }
        }
        if let best { return best.url }
        guard isWeb(page), var parts = URLComponents(url: page, resolvingAgainstBaseURL: false) else { return nil }
        parts.path = "/favicon.ico"
        parts.query = nil
        parts.fragment = nil
        return parts.url
    }

    private static func isWeb(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return (scheme == "http" || scheme == "https") && url.host?.isEmpty == false
    }

    private static func download(_ url: URL, then: @escaping (NSImage?) -> Void) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        let loader = Download(limit: maxBytes) { data in then(data.flatMap(decode)) }
        let session = URLSession(configuration: configuration, delegate: loader, delegateQueue: queue)
        session.dataTask(with: url).resume()
        session.finishTasksAndInvalidate()
    }

    // Read the pixel size before decoding: a small file can still hold a huge bitmap. An .ico
    // holds several sizes; the largest reasonable one is scaled down to what the strip draws.
    private static func decode(_ data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        var best: (index: Int, size: Int)?
        for index in 0..<min(CGImageSourceGetCount(source), 16) {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 1024, height <= 1024 else { continue }
            if best.map({ max(width, height) > $0.size }) ?? true { best = (index, max(width, height)) }
        }
        guard let best else { return nil }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                       kCGImageSourceThumbnailMaxPixelSize: 64,
                       kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, best.index, options),
              image.width > 0, image.height > 0 else { return nil }
        let height = 16 * CGFloat(image.height) / CGFloat(image.width)
        return NSImage(cgImage: image, size: NSSize(width: 16, height: height))
    }

    private final class Download: NSObject, URLSessionDataDelegate {
        private let limit: Int
        private let done: (Data?) -> Void
        private var data = Data()
        private var failed = false

        init(limit: Int, done: @escaping (Data?) -> Void) {
            self.limit = limit
            self.done = done
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let ok = (200..<300).contains(status) && response.expectedContentLength <= Int64(limit)
            if !ok { failed = true }
            completionHandler(ok ? .allow : .cancel)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            self.data.append(data)
            if self.data.count > limit {
                failed = true
                dataTask.cancel()
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            done(error == nil && !failed ? data : nil)
        }
    }
}

enum DRMCheckCLI {
    static func run(_ args: [String]) -> Bool {
        guard args.count >= 2, args[1] == "--drm-check" else { return false }
        NSApp.setActivationPolicy(.prohibited)
        let frame = NSRect(x: 0, y: 0, width: 320, height: 200)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        let webView = WKWebView(frame: frame, configuration: GuideContent.configuration(reader: false))
        window.contentView?.addSubview(webView)
        var done = false
        let probe = Probe { done = true }
        webView.navigationDelegate = probe
        // An https base URL makes a secure context, which EME requires; the page loads nothing.
        webView.loadHTMLString("<!doctype html><meta charset=\"utf-8\"><title>DRM check</title>",
                               baseURL: URL(string: "https://drm-check.slyterm.invalid/"))
        let deadline = Date().addingTimeInterval(20)
        while !done, Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        if !done { print("timed out") }
        withExtendedLifetime((window, probe)) {}
        return true
    }

    private static let check = """
    const out = { agent: navigator.userAgent, secure: String(window.isSecureContext) };
    const config = [{
      initDataTypes: ["cenc", "sinf", "skd"],
      videoCapabilities: [{ contentType: 'video/mp4; codecs="avc1.640028"' }],
      audioCapabilities: [{ contentType: 'audio/mp4; codecs="mp4a.40.2"' }]
    }];
    if (!navigator.requestMediaKeySystemAccess) {
      out.access = "not available";
      out.keys = "not tried";
    } else {
      try {
        const access = await navigator.requestMediaKeySystemAccess("com.apple.fps", config);
        out.access = "granted (" + access.keySystem + ")";
        try { await access.createMediaKeys(); out.keys = "created"; } catch (e) { out.keys = "failed: " + e; }
      } catch (e) {
        out.access = "failed: " + e;
        out.keys = "not tried";
      }
    }
    out.legacy = typeof WebKitMediaKeys === "undefined" ? "no WebKitMediaKeys"
      : String(WebKitMediaKeys.isTypeSupported("com.apple.fps.1_0", "video/mp4"));
    return out;
    """

    private final class Probe: NSObject, WKNavigationDelegate {
        private let finished: () -> Void
        init(finished: @escaping () -> Void) { self.finished = finished }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.callAsyncJavaScript(DRMCheckCLI.check, arguments: [:], in: nil, in: .page) { [finished] result in
                switch result {
                case .success(let value):
                    let out = value as? [String: Any] ?? [:]
                    print("user agent: \(out["agent"] ?? "?")")
                    print("secure context: \(out["secure"] ?? "?")")
                    print("requestMediaKeySystemAccess(com.apple.fps): \(out["access"] ?? "?")")
                    print("createMediaKeys: \(out["keys"] ?? "?")")
                    print("WebKitMediaKeys.isTypeSupported(com.apple.fps.1_0, video/mp4): \(out["legacy"] ?? "?")")
                case .failure(let error):
                    print("check failed: \(error.localizedDescription)")
                }
                finished()
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            print("load failed: \(error.localizedDescription)")
            finished()
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            print("load failed: \(error.localizedDescription)")
            finished()
        }
    }
}
