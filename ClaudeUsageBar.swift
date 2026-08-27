import Cocoa
import Foundation

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var fiveHour: Double?
    var sevenDay: Double?
    var fiveHourReset: Date?
    var sevenDayReset: Date?
    var scopedSevenDay: Double?        // model-scoped weekly (today: Fable)
    var scopedSevenDayReset: Date?
    var scopedLabel: String?           // display name from the API payload
    var lastUpdate: Date?

    // Bar shows the scoped weekly only when this is on (menu toggle,
    // persisted). The dropdown row shows whenever data exists, regardless.
    let showScopedKey = "ShowScopedWeekly"
    var showScopedWeekly: Bool { UserDefaults.standard.bool(forKey: showScopedKey) }
    var fetchStatus: String?   // "ok" | "token_expired" | "error" — written by the updater
    var statusDetail: String?

    let cacheFile = NSString(string: "~/.claude/rate-limits.json").expandingTildeInPath
    let statusFile = NSString(string: "~/.claude/rate-limits-status.json").expandingTildeInPath
    let updaterScript = NSString(string: "~/.claude/usage-bar/update-rate-limits.sh").expandingTildeInPath
    let stalenessThreshold: TimeInterval = 300 // 5 min — when to dim + label "(stale)"
    let refreshInterval: TimeInterval = 45     // trigger a fetch once the cache is older than this
    var updaterRunning = false                 // guard against overlapping spawns
    var updaterStartedAt: Date?                // for the wedge watchdog below

    lazy var clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // Opt out of App Nap. macOS aggressively throttles accessory/menu-bar
        // apps during idle, which freezes our run-loop Timer — the real cause
        // of the recurring staleness: the poller stopped firing while the
        // system was awake but the app was napped. NSAppSleepDisabled is the
        // documented, sleep-safe way to exempt the app: it stops App Nap
        // without preventing normal system/display sleep.
        UserDefaults.standard.set(true, forKey: "NSAppSleepDisabled")

        readCache()
        buildMenu()

        // The app is the active poller. Every 15s: re-read the cache, and if
        // it's older than refreshInterval, spawn the updater to fetch fresh
        // data. This does NOT rely on the LaunchAgent's StartInterval or on
        // wake notifications — both are suppressed on Macs that sleep often
        // (StartInterval doesn't fire while asleep; wake events miss DarkWake
        // and display-only sleep). A run-loop timer instead simply resumes
        // ticking the moment the process is scheduled again after wake, so as
        // long as the app is running and the Mac is awake, data stays fresh.
        // Scheduled on .common modes so it keeps firing during menu tracking.
        let timer = Timer(timeInterval: 15.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        tick()

        // Extra nudge on wake when it does fire — harmless, just faster.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil)
    }

    func tick() {
        readCache()
        buildMenu()
        if cacheAge > refreshInterval { runUpdater() }
    }

    @objc func systemDidWake() {
        runUpdater()
    }

    // Spawn update-rate-limits.sh. Keychain access inside it goes through
    // /usr/bin/security (Apple-signed, trusted in the item's ACL), so it
    // stays silent even though this parent app is only ad-hoc signed — the
    // keychain call is attributed to security, not to us.
    func runUpdater() {
        // Wedge watchdog: a previous spawn can leave updaterRunning stuck true
        // if its terminationHandler is never delivered (the main queue can
        // stall when the system suspends the app). A real run finishes in a few
        // seconds (curl -m 5), so if the flag has been set longer than 30s,
        // treat the old spawn as dead and proceed instead of blocking forever.
        if updaterRunning {
            if let started = updaterStartedAt, Date().timeIntervalSince(started) < 30 {
                return
            }
        }
        updaterRunning = true
        updaterStartedAt = Date()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [updaterScript]
        var env = ProcessInfo.processInfo.environment
        env["LAUNCH_SRC"] = "app"
        task.environment = env
        task.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.updaterRunning = false
                self?.readCache()
                self?.buildMenu()
            }
        }
        do {
            try task.run()
        } catch {
            updaterRunning = false
        }
    }

    // NSMenuDelegate: re-read the cache every time the user opens the menu so
    // the values are current the instant they look. If the cache is stale
    // (e.g. just woke up), also kick the updater so it self-heals while the
    // menu is open.
    func menuWillOpen(_ menu: NSMenu) {
        readCache()
        buildMenu()
        if isStale { runUpdater() }
    }

    // Latest fetch outcome from the updater, so the menu can show a precise
    // reason ("token expired") instead of a bare "(stale)". The app itself
    // never reads the keychain — the updater hands it this status file.
    func readStatus() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: statusFile)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            fetchStatus = nil; statusDetail = nil
            return
        }
        fetchStatus = json["status"] as? String
        statusDetail = json["detail"] as? String
    }

    func readCache() {
        readStatus()
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: cacheFile)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            fiveHour = nil; sevenDay = nil
            fiveHourReset = nil; sevenDayReset = nil
            scopedSevenDay = nil; scopedSevenDayReset = nil; scopedLabel = nil
            lastUpdate = nil
            updateTitle()
            return
        }

        fiveHour = (json["five_hour"] as? Double).flatMap { $0.isNaN ? nil : $0 }
        sevenDay = (json["seven_day"] as? Double).flatMap { $0.isNaN ? nil : $0 }
        if let r = json["five_hour_reset"] as? Double, r > 0 {
            fiveHourReset = Date(timeIntervalSince1970: r)
        }
        if let r = json["seven_day_reset"] as? Double, r > 0 {
            sevenDayReset = Date(timeIntervalSince1970: r)
        }
        // Scoped weekly keys exist only when the rich usage endpoint served
        // the cache; the probe fallback omits them and the slot disappears.
        scopedSevenDay = (json["scoped_7d"] as? Double).flatMap { $0.isNaN ? nil : $0 }
        scopedLabel = json["scoped_7d_label"] as? String
        if let r = json["scoped_7d_reset"] as? Double, r > 0 {
            scopedSevenDayReset = Date(timeIntervalSince1970: r)
        } else {
            scopedSevenDayReset = nil
        }
        if let ts = json["timestamp"] as? Double {
            lastUpdate = Date(timeIntervalSince1970: ts)
        }

        updateTitle()
    }

    var cacheAge: TimeInterval {
        guard let lu = lastUpdate else { return .greatestFiniteMagnitude }
        return Date().timeIntervalSince(lu)
    }

    var isStale: Bool {
        return cacheAge > stalenessThreshold
    }

    // When a window's reset has already passed AND our cached data predates
    // that reset, the window has rolled over since we last fetched — so unless
    // work happened (and if it had, a fresh fetch would have landed), the true
    // utilization is ~0. Project to 0 and flag it. Flagged values are dimmed
    // to signal "estimated, not freshly confirmed". The reset countdown is
    // intentionally left showing "now" until a real fetch confirms the window.
    func projected(_ percent: Double?, reset: Date?) -> (pct: Double?, isProjected: Bool) {
        guard let percent = percent, let reset = reset else {
            return (percent, false)
        }
        // No timestamp means we can't confirm the data is post-rollover, so
        // treat it as old: a reset that has already passed still projects to 0.
        let lu = lastUpdate ?? Date.distantPast
        if lu < reset && Date() > reset {
            return (0, true)
        }
        return (percent, false)
    }

    // Green (0%) → Yellow (50%) → Red (100%).
    // `darkened` knocks brightness down for readability on light menu backgrounds.
    func colorForPercent(_ pct: Double, alpha: CGFloat = 1.0, darkened: Bool = false) -> NSColor {
        let t = min(max(pct / 100.0, 0), 1)
        let r: CGFloat
        let g: CGFloat
        if t < 0.5 {
            r = CGFloat(t * 2.0)
            g = 1.0
        } else {
            r = 1.0
            g = CGFloat((1.0 - t) * 2.0)
        }
        let scale: CGFloat = darkened ? 0.6 : 1.0
        return NSColor(red: r * scale, green: g * scale, blue: 0, alpha: alpha)
    }

    // The separator cell rendered as a 5h-window countdown: five stacked
    // segments, one per hour. Bright segments are whole hours still ahead,
    // the in-progress hour fades with its remaining fraction, spent hours
    // stay as faint stubs. Drawn at exactly the "|" advance width so the
    // status item footprint doesn't change. Returns nil when no window is
    // active (no data, or the reset already passed) — caller falls back to
    // the plain "|".
    func fiveHourNotches(dim: CGFloat, font: NSFont) -> NSAttributedString? {
        guard fiveHour != nil, let reset = fiveHourReset else { return nil }
        let remaining = reset.timeIntervalSinceNow / 18000.0
        guard remaining > 0 else { return nil }
        let hoursLeft = min(remaining, 1.0) * 5.0
        let full = Int(hoursLeft + 1e-9)
        let frac = CGFloat(hoursLeft - Double(full))

        let width = ("|" as NSString).size(withAttributes: [.font: font]).width
        // Span the font's full line box — ascender to descender, ~12pt, the
        // same vertical extent the old "|" glyph occupied. This is the
        // practical ceiling for a text attachment: the status-bar button
        // lays the title out against the font's own line metrics and CLIPS
        // whatever an attachment adds beyond them (an 18pt attempt rendered
        // fine via NSStringDrawing but came back clipped to cap height in
        // the real bar). Going genuinely taller than the line box means a
        // custom button subview, not text.
        let ascent = font.ascender
        let descent = abs(font.descender)
        let height = ascent + descent
        let gap: CGFloat = 0.8
        let segH = (height - 4 * gap) / 5
        let segW: CGFloat = 2.4
        let x = (width - segW) / 2

        // Handler-based NSImage: the closure re-runs on every draw, so
        // labelColor resolves against the menu bar's appearance at that
        // moment — a flat bitmap would bake in whichever mode was active
        // when the title was built and stop adapting.
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            for i in 0..<5 {
                let alpha: CGFloat
                if i < full {
                    alpha = 0.95
                } else if i == full {
                    alpha = max(0.25, frac * 0.95)
                } else {
                    // 0.25, not fainter: wallpaper-tinted menu bars swallow
                    // anything below ~0.2 and the column reads as a colon.
                    alpha = 0.25
                }
                NSColor.labelColor.withAlphaComponent(alpha * dim).setFill()
                let y = CGFloat(i) * (segH + gap)
                NSBezierPath(roundedRect: NSRect(x: x, y: y, width: segW, height: segH),
                             xRadius: 0.8, yRadius: 0.8).fill()
            }
            return true
        }

        let attachment = NSTextAttachment()
        attachment.image = image
        // Bottom at the descender line, top at the ascender — exactly the
        // box the digits' font already claims, so line metrics (and the
        // digits' position) don't move.
        attachment.bounds = CGRect(x: 0, y: -descent, width: width, height: height)
        return NSAttributedString(attachment: attachment)
    }

    // The right column when "show Fable weekly" is on: all-models weekly
    // stacked over the scoped (Fable) weekly at ~7.5pt, each colored by its
    // own utilization. Same attachment technique as the notches: drawn in
    // the big font's line box so nothing shifts, colors resolved per draw.
    func stackedWeeklies(top: Double, topAlpha: CGFloat, bottom: Double,
                         bottomAlpha: CGFloat, font: NSFont) -> NSAttributedString {
        let small = NSFont.monospacedSystemFont(ofSize: 7.5, weight: .medium)
        let topAttr: [NSAttributedString.Key: Any] = [
            .font: small, .foregroundColor: colorForPercent(top, alpha: topAlpha)]
        let botAttr: [NSAttributedString.Key: Any] = [
            .font: small, .foregroundColor: colorForPercent(bottom, alpha: bottomAlpha)]
        let topStr = NSAttributedString(string: String(format: "%.0f", top), attributes: topAttr)
        let botStr = NSAttributedString(string: String(format: "%.0f", bottom), attributes: botAttr)

        let ascent = font.ascender
        let descent = abs(font.descender)
        let height = ascent + descent
        let pad: CGFloat = 1.2   // breathing room after the notch column
        let width = max(topStr.size().width, botStr.size().width) + pad

        // Rows fill the box: bottom row baseline on the box floor, top row
        // cap flush with the box top, gap is whatever remains between caps.
        let capS = small.capHeight
        let topBaseline = height - capS
        // draw(at:) in an unflipped context puts the point at the line box's
        // bottom-left, |descender| below the baseline — offset for that.
        let baselineToBox = small.descender   // negative

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            botStr.draw(at: NSPoint(x: pad, y: 0 + baselineToBox))
            topStr.draw(at: NSPoint(x: pad, y: topBaseline + baselineToBox))
            return true
        }

        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(x: 0, y: -descent, width: width, height: height)
        return NSAttributedString(attachment: attachment)
    }

    func updateTitle() {
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        let result = NSMutableAttributedString()

        // Dim per-window when the cache is stale OR the value is a rolled-over
        // projection — both mean "not freshly confirmed".
        let (fhPct, fhProj) = projected(fiveHour, reset: fiveHourReset)
        let (sdPct, sdProj) = projected(sevenDay, reset: sevenDayReset)
        let fhAlpha: CGFloat = (isStale || fhProj) ? 0.5 : 1.0
        let sdAlpha: CGFloat = (isStale || sdProj) ? 0.5 : 1.0

        let fhStr = fhPct.map { String(format: "%.0f", $0) } ?? "--"
        let fhColor = fhPct != nil
            ? colorForPercent(fhPct ?? 0, alpha: fhAlpha)
            : NSColor.tertiaryLabelColor
        result.append(NSAttributedString(string: fhStr, attributes: [.font: font, .foregroundColor: fhColor]))

        // Separator doubles as the 5h-window clock (hour notches). Dimmed by
        // fhAlpha since it describes the 5h window specifically.
        if let notches = fiveHourNotches(dim: fhAlpha, font: font) {
            result.append(notches)
        } else {
            // labelColor adapts to light/dark menu bars; plain white vanishes
            // on a light menu bar.
            let sepColor = NSColor.labelColor.withAlphaComponent(max(fhAlpha, sdAlpha))
            result.append(NSAttributedString(string: "|", attributes: [.font: font, .foregroundColor: sepColor]))
        }

        // Right column: with the toggle on and scoped data present, stack
        // all-models weekly over the scoped weekly; otherwise the classic
        // single full-size number (also the fallback when data is absent).
        let (scPct, scProj) = projected(scopedSevenDay, reset: scopedSevenDayReset)
        let scAlpha: CGFloat = (isStale || scProj) ? 0.5 : 1.0
        if showScopedWeekly, let sd = sdPct, let sc = scPct {
            result.append(stackedWeeklies(top: sd, topAlpha: sdAlpha,
                                          bottom: sc, bottomAlpha: scAlpha, font: font))
        } else {
            let sdStr = sdPct.map { String(format: "%.0f", $0) } ?? "--"
            let sdColor = sdPct != nil
                ? colorForPercent(sdPct ?? 0, alpha: sdAlpha)
                : NSColor.tertiaryLabelColor
            result.append(NSAttributedString(string: sdStr, attributes: [.font: font, .foregroundColor: sdColor]))
        }

        DispatchQueue.main.async {
            self.statusItem.button?.attributedTitle = result
        }
    }

    func timeUntil(_ date: Date?) -> String {
        guard let date = date else { return "N/A" }
        let diff = Int(date.timeIntervalSinceNow)
        if diff <= 0 { return "now" }
        let d = diff / 86400
        let h = (diff % 86400) / 3600
        let m = (diff % 3600) / 60
        var parts: [String] = []
        if d > 0 { parts.append("\(d)d") }
        if d > 0 || h > 0 { parts.append("\(h)h") }
        parts.append("\(m)m")
        return parts.joined(separator: " ")
    }

    func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self

        let (fhPct, fhProj) = projected(fiveHour, reset: fiveHourReset)
        let fhStr = fhPct.map { String(format: "%.1f%%", $0) } ?? "N/A"
        let fhItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        fhItem.attributedTitle = coloredMenuItem(
            "5h   \(fhStr)  resets \(timeUntil(fiveHourReset))",
            pct: fhPct ?? 0,
            hasData: fhPct != nil,
            dim: isStale || fhProj)
        fhItem.isEnabled = false
        menu.addItem(fhItem)

        let (sdPct, sdProj) = projected(sevenDay, reset: sevenDayReset)
        let sdStr = sdPct.map { String(format: "%.1f%%", $0) } ?? "N/A"
        let sdItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        sdItem.attributedTitle = coloredMenuItem(
            "7d   \(sdStr)  resets \(timeUntil(sevenDayReset))",
            pct: sdPct ?? 0,
            hasData: sdPct != nil,
            dim: isStale || sdProj)
        sdItem.isEnabled = false
        menu.addItem(sdItem)

        // Scoped weekly row: shown whenever data exists, independent of the
        // bar toggle. Absent on probe-fallback data, which has no such bucket.
        if let scRaw = scopedSevenDay {
            let (scPct, scProj) = projected(scRaw, reset: scopedSevenDayReset)
            let scStr = scPct.map { String(format: "%.1f%%", $0) } ?? "N/A"
            let scItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            scItem.attributedTitle = coloredMenuItem(
                "7d \(scopedLabel ?? "Fable")  \(scStr)  resets \(timeUntil(scopedSevenDayReset))",
                pct: scPct ?? 0,
                hasData: scPct != nil,
                dim: isStale || scProj)
            scItem.isEnabled = false
            menu.addItem(scItem)
        }

        menu.addItem(NSMenuItem.separator())
        let updatedText: String
        if let lu = lastUpdate {
            let suffix: String
            if fetchStatus == "token_expired" {
                suffix = "  token expired, open a Claude client"
            } else if isStale {
                suffix = "  (stale)"
            } else {
                suffix = ""
            }
            updatedText = "updated \(clockFormatter.string(from: lu))\(suffix)"
        } else if fetchStatus == "token_expired" {
            updatedText = "token expired, open a Claude client"
        } else {
            updatedText = "no data, run any Claude Code command"
        }
        let luItem = NSMenuItem(title: updatedText, action: nil, keyEquivalent: "")
        luItem.isEnabled = false
        menu.addItem(luItem)

        menu.addItem(NSMenuItem.separator())

        let toggleItem = NSMenuItem(title: "Show \(scopedLabel ?? "Fable") weekly",
                                    action: #selector(toggleScopedWeekly), keyEquivalent: "")
        toggleItem.target = self
        toggleItem.state = showScopedWeekly ? .on : .off
        menu.addItem(toggleItem)

        let refreshItem = NSMenuItem(title: "Refresh now", action: #selector(refreshNow), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let openItem = NSMenuItem(title: "Usage Page...", action: #selector(openUsage), keyEquivalent: "u")
        openItem.target = self
        menu.addItem(openItem)

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    func coloredMenuItem(_ text: String, pct: Double, hasData: Bool, dim: Bool = false) -> NSAttributedString {
        let base = hasData ? colorForPercent(pct, darkened: true) : NSColor.secondaryLabelColor
        let color = dim ? base.withAlphaComponent(0.5) : base
        return NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium),
            .foregroundColor: color
        ])
    }

    @objc func toggleScopedWeekly() {
        UserDefaults.standard.set(!showScopedWeekly, forKey: showScopedKey)
        buildMenu()
        updateTitle()
    }

    @objc func refreshNow() {
        // Force an immediate fetch regardless of cache age. Reset the watchdog
        // flag first so a (rare) wedged spawn can't swallow the manual press.
        updaterRunning = false
        runUpdater()
    }

    @objc func openUsage() {
        NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!)
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
