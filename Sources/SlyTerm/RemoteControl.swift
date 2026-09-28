import AppKit

enum RemoteControl {
    @MainActor
    static func handle(_ urls: [URL], controller: OverlayController) {
        for url in urls where url.scheme == "slyterm" {
            let action = (url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).lowercased()
            Settings.log("remote control: \(action)")
            switch action {
            case "toggle": controller.toggleVisible()
            case "show": controller.show()
            case "hide": controller.hide()
            case "ghost": controller.toggleGhost()
            case "panic": controller.togglePanic()
            case "notify", "attention":
                if let tab = target(of: url, controller: controller) { controller.requestAttention(tab) }
                Activity.monitor?.refreshNow(completion: nil)
            case "allow", "refuse":
                // Own opt-in: any local process can open a URL, the agent being answered too.
                guard Settings.shared.activityAnswerURLs else {
                    Settings.log("\(action): ignored, activityAnswerURLs is off")
                    let strip = controller.stripScreenFrame
                    Toast.shared.show("slyterm://\(action) is off (activityAnswerURLs)",
                                      near: strip.isEmpty ? NSEvent.mouseLocation : NSPoint(x: strip.maxX, y: strip.maxY),
                                      tint: .systemOrange)
                    break
                }
                let answer: ActivityAnswer.Answer = action == "allow" ? .allow : .refuse
                guard value(of: "tab", in: url) != nil else { ActivityAnswer.perform(answer); break }
                guard let tab = target(of: url, controller: controller) as? TerminalTab else {
                    Settings.log("\(action): no terminal tab named, ignored")
                    break
                }
                ActivityAnswer.perform(answer, tab: tab)
            case "hotkeys": (NSApp.delegate as? AppDelegate)?.openSettings(tab: .shortcuts)
            case "settings": (NSApp.delegate as? AppDelegate)?.openSettings()
            case "lookup", "quest", "pick":
                var game: LookupGame?
                if let name = value(of: "game", in: url) {
                    guard let named = LookupStore.shared.game(named: name) else {
                        Settings.log("lookup: no game named \"\(name)\", ignored")
                        Toast.shared.show("No game named “\(name)”", near: NSEvent.mouseLocation, tint: .systemOrange)
                        break
                    }
                    game = named
                }
                let dryRun = value(of: "dry", in: url) != nil
                if action == "pick" || value(of: "pick", in: url) != nil {
                    Lookup.shared.pick(dryRun: dryRun, game: game)
                } else {
                    Lookup.shared.trigger(dryRun: dryRun, text: value(of: "q", in: url, plusIsSpace: true), game: game)
                }
            case "guide": controller.showGuide(page(of: url))
            case "web":
                guard let page = page(of: url) else { Settings.log("web: no http or https url, ignored"); break }
                controller.openWebTab(page, select: true, focusAddress: false)
            case "playpause": controller.playPause()
            case "teleport": TeleportEngine.shared.handleRemote(url)
            default: break
            }
        }
    }

    private static func target(of url: URL, controller: OverlayController) -> Tab? {
        guard let value = value(of: "tab", in: url) else { return controller.current }
        let match: Tab? = UUID(uuidString: value).flatMap { uuid in controller.tabs.first { $0.id == uuid } }
            ?? Int(value).flatMap { n in controller.terminals.indices.contains(n - 1) ? controller.terminals[n - 1] : nil }
        if match == nil { Settings.log("notify: no tab \"\(value)\", ignored") }
        return match
    }

    // URLComponents leaves `+` as is; plusIsSpace is for typed free text, never a URL value.
    private static func value(of name: String, in url: URL, plusIsSpace: Bool = false) -> String? {
        var value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name.lowercased() == name }?.value
        if plusIsSpace { value = value?.replacingOccurrences(of: "+", with: " ") }
        let trimmed = value?.trimmingCharacters(in: .whitespaces)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    private static func page(of url: URL) -> URL? {
        guard let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name.lowercased() == "url" })?.value,
            let page = URL(string: value), ["http", "https"].contains(page.scheme?.lowercased() ?? "") else { return nil }
        return page
    }
}
