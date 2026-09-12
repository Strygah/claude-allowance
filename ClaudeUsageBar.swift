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
    var scopedFetchedAt: Date?         // last REAL scoped fetch (probe fallback carries old values)

    // Codex (OpenAI) subscription windows, from ~/.claude/codex-limits.json.
    var codexFiveHour: Double?
    var codexFiveHourReset: Date?
    var codexWindow: TimeInterval = 18000
    var codexSevenDay: Double?
    var codexSevenDayReset: Date?
    var codexFetchedAt: Date?
    var codexStatus: String?           // ok | expired | error; nil = no Codex on this Mac
    let codexCacheFile = NSString(string: "~/.claude/codex-limits.json").expandingTildeInPath

    // Which vendor(s) the bar shows. Default: Claude only. "both" stacks
    // Claude over Codex as two mini rows.
    enum BarVendors: String { case claude, codex, both }
    let barVendorsKey = "BarVendors"
    var barVendors: BarVendors {
        BarVendors(rawValue: UserDefaults.standard.string(forKey: barVendorsKey) ?? "claude") ?? .claude
    }
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
    let refreshInterval: TimeInterval = 170    // spawn the updater once the cache is older than this (its own cadence gate is 180s)
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
    func runUpdater(force: Bool = false) {
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
        if force { env["FORCE"] = "1" }   // "Refresh now" bypasses the fetch cadence
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
        readCodexCache()
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: cacheFile)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            fiveHour = nil; sevenDay = nil
            fiveHourReset = nil; sevenDayReset = nil
            scopedSevenDay = nil; scopedSevenDayReset = nil; scopedLabel = nil
            scopedFetchedAt = nil
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
        scopedFetchedAt = (json["scoped_7d_fetched_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
        if let ts = json["timestamp"] as? Double {
            lastUpdate = Date(timeIntervalSince1970: ts)
        }

        updateTitle()
    }

    func readCodexCache() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: codexCacheFile)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            codexStatus = nil; codexFiveHour = nil; codexSevenDay = nil
            codexFiveHourReset = nil; codexSevenDayReset = nil; codexFetchedAt = nil
            return
        }
        codexStatus = json["status"] as? String ?? "ok"
        codexFiveHour = (json["five_hour"] as? Double).flatMap { $0.isNaN ? nil : $0 }
        codexSevenDay = (json["seven_day"] as? Double).flatMap { $0.isNaN ? nil : $0 }
        codexFiveHourReset = (json["five_hour_reset"] as? Double).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
        codexSevenDayReset = (json["seven_day_reset"] as? Double).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
        if let w = json["five_hour_window"] as? Double, w > 0 { codexWindow = w }
        codexFetchedAt = (json["timestamp"] as? Double).map { Date(timeIntervalSince1970: $0) }
    }

    var codexStale: Bool {
        guard codexStatus == "ok", let t = codexFetchedAt else { return true }
        return Date().timeIntervalSince(t) > stalenessThreshold
    }

    var cacheAge: TimeInterval {
        guard let lu = lastUpdate else { return .greatestFiniteMagnitude }
        return Date().timeIntervalSince(lu)
    }

    var isStale: Bool {
        return cacheAge > stalenessThreshold
    }

    // The scoped weekly can be a carried-over value while the rich endpoint
    // is down (probe fallback has no scoped bucket), so it has its own
    // staleness clock, keyed on the last real fetch rather than the cache.
    var scopedAge: TimeInterval? {
        return scopedFetchedAt.map { Date().timeIntervalSince($0) }
    }
    var scopedStale: Bool {
        guard let age = scopedAge else { return true }
        return age > stalenessThreshold
    }

    func ageString(_ interval: TimeInterval) -> String {
        let m = Int(interval / 60)
        if m < 60 { return "\(m)m" }
        return "\(m / 60)h \(m % 60)m"
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

    // The whole item is rendered as ONE image, not attributed text. The
    // text-layout route caps glyph height at the font's line box (~12pt) —
    // the status button clips anything an attachment adds beyond it. An
    // image sidesteps that: the button centers it in the bar, clicks and
    // the menu behave identically, and a handler-based NSImage re-runs its
    // drawing closure per draw so labelColor keeps adapting to light/dark.
    let barHeight: CGFloat = 22   // fits every menu bar (min thickness 24)

    // Continuous 5h gauge, notched into 5 hour segments by thin gaps.
    // Bright fill height = exact remaining fraction of the window (drains
    // downward); the faint track shows the full extent. Whole hours left
    // are still countable as fully-lit segments.
    func drawGaugeColumn(x: CGFloat, cellWidth: CGFloat, top: CGFloat, height: CGFloat,
                         segW: CGFloat, remaining: Double, dim: CGFloat) {
        let rem = min(max(remaining, 0), 1)
        let inset: CGFloat = 1.0
        let usable = height - 2 * inset
        let gap: CGFloat = height >= 18 ? 0.9 : 0.6
        let segH = (usable - 4 * gap) / 5
        let segX = x + (cellWidth - segW) / 2
        let radius = segW * 0.3
        for i in 0..<5 {
            let y = top + inset + CGFloat(i) * (segH + gap)
            let f = min(max(rem * 5 - Double(i), 0), 1)
            NSColor.labelColor.withAlphaComponent(0.18 * dim).setFill()
            NSBezierPath(roundedRect: NSRect(x: segX, y: y, width: segW, height: segH),
                         xRadius: radius, yRadius: radius).fill()
            if f > 0.01 {
                NSColor.labelColor.withAlphaComponent(0.95 * dim).setFill()
                NSBezierPath(roundedRect: NSRect(x: segX, y: y, width: segW, height: segH * CGFloat(f)),
                             xRadius: radius, yRadius: radius).fill()
            }
        }
    }

    // One vendor's pre-styled numbers plus its 5h clock state.
    struct VendorRow {
        var left: NSAttributedString          // 5h percent
        var right: NSAttributedString         // weekly percent
        var rightBottom: NSAttributedString?  // stacked second weekly (Fable), Claude-only mode
        var remaining: Double?                // fraction of the 5h window left; nil = no active window
        var gaugeDim: CGFloat
        var sepAlpha: CGFloat
    }

    func styled(_ pct: Double?, alpha: CGFloat, font: NSFont) -> NSAttributedString {
        let color = pct != nil ? colorForPercent(pct ?? 0, alpha: alpha) : NSColor.tertiaryLabelColor
        return NSAttributedString(string: pct.map { String(format: "%.0f", $0) } ?? "--",
                                  attributes: [.font: font, .foregroundColor: color])
    }

    func claudeRow(font: NSFont, stacked: Bool) -> VendorRow {
        // Dim per-window when the cache is stale OR the value is a rolled-over
        // projection — both mean "not freshly confirmed".
        let (fhPct, fhProj) = projected(fiveHour, reset: fiveHourReset)
        let (sdPct, sdProj) = projected(sevenDay, reset: sevenDayReset)
        let (scPct, scProj) = projected(scopedSevenDay, reset: scopedSevenDayReset)
        let fhAlpha: CGFloat = (isStale || fhProj) ? 0.5 : 1.0
        let sdAlpha: CGFloat = (isStale || sdProj) ? 0.5 : 1.0
        let scAlpha: CGFloat = (isStale || scProj || scopedStale) ? 0.5 : 1.0
        var rem: Double? = nil
        if fiveHour != nil, let reset = fiveHourReset {
            let r = reset.timeIntervalSinceNow / 18000.0
            if r > 0 { rem = r }
        }
        let useStack = stacked && sdPct != nil && scPct != nil
        return VendorRow(left: styled(fhPct, alpha: fhAlpha, font: font),
                         right: styled(sdPct, alpha: sdAlpha, font: font),
                         rightBottom: useStack ? styled(scPct, alpha: scAlpha, font: font) : nil,
                         remaining: rem, gaugeDim: fhAlpha, sepAlpha: max(fhAlpha, sdAlpha))
    }

    func codexRow(font: NSFont) -> VendorRow {
        let now = Date()
        func proj(_ pct: Double?, _ reset: Date?) -> (Double?, Bool) {
            guard let p = pct, let r = reset else { return (pct, false) }
            if (codexFetchedAt ?? Date.distantPast) < r && now > r { return (0, true) }
            return (p, false)
        }
        let (fhPct, fhProj) = proj(codexFiveHour, codexFiveHourReset)
        let (sdPct, sdProj) = proj(codexSevenDay, codexSevenDayReset)
        let fhAlpha: CGFloat = (codexStale || fhProj) ? 0.5 : 1.0
        let sdAlpha: CGFloat = (codexStale || sdProj) ? 0.5 : 1.0
        var rem: Double? = nil
        if codexFiveHour != nil, let reset = codexFiveHourReset {
            let r = reset.timeIntervalSinceNow / codexWindow
            if r > 0 { rem = r }
        }
        return VendorRow(left: styled(fhPct, alpha: fhAlpha, font: font),
                         right: styled(sdPct, alpha: sdAlpha, font: font), rightBottom: nil,
                         remaining: rem, gaugeDim: fhAlpha, sepAlpha: max(fhAlpha, sdAlpha))
    }

    // Draw one row into [top, top+height]: 5h digits, gauge cell, weekly.
    func drawRow(_ row: VendorRow, x0: CGFloat, top: CGFloat, height: CGFloat,
                 font: NSFont, cellW: CGFloat, segW: CGFloat) {
        // draw(at:) in an unflipped context takes the line box's bottom-left,
        // |descender| below the baseline; to put a cap box at [y, y+capHeight]
        // draw at y + descender.
        let dY = top + (height - font.capHeight) / 2
        row.left.draw(at: NSPoint(x: x0, y: dY + font.descender))
        let cellX = x0 + row.left.size().width
        if let rem = row.remaining {
            drawGaugeColumn(x: cellX, cellWidth: cellW, top: top, height: height,
                            segW: segW, remaining: rem, dim: row.gaugeDim)
        } else {
            let w: CGFloat = segW * 0.42
            NSColor.labelColor.withAlphaComponent(row.sepAlpha).setFill()
            NSBezierPath(roundedRect: NSRect(x: cellX + (cellW - w) / 2, y: top + 1.0,
                                             width: w, height: height - 2.0),
                         xRadius: w / 2, yRadius: w / 2).fill()
        }
        let rightX = cellX + cellW
        if let bottom = row.rightBottom {
            let inset: CGFloat = 1.2
            bottom.draw(at: NSPoint(x: rightX, y: top + inset + font.descender))
            let topBase = top + height - inset - font.capHeight
            row.right.draw(at: NSPoint(x: rightX, y: topBase + font.descender))
        } else {
            row.right.draw(at: NSPoint(x: rightX, y: dY + font.descender))
        }
    }

    func rowWidth(_ row: VendorRow, cellW: CGFloat) -> CGFloat {
        return row.left.size().width + cellW + max(row.right.size().width, row.rightBottom?.size().width ?? 0)
    }

    func updateTitle() {
        let pad: CGFloat = 1.0
        let H = barHeight
        var rows: [VendorRow] = []
        let font: NSFont
        let cellW: CGFloat
        let segW: CGFloat
        switch barVendors {
        case .claude:
            font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium); cellW = 5.0; segW = 2.6
            rows = [claudeRow(font: font, stacked: showScopedWeekly)]
        case .codex:
            font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium); cellW = 5.0; segW = 2.6
            rows = [codexRow(font: font)]
        case .both:
            font = NSFont.monospacedSystemFont(ofSize: 8.5, weight: .medium); cellW = 4.4; segW = 2.2
            rows = [claudeRow(font: font, stacked: false), codexRow(font: font)]
        }
        let width = pad + (rows.map { rowWidth($0, cellW: cellW) }.max() ?? 20) + pad

        let image = NSImage(size: NSSize(width: width, height: H), flipped: false) { [self] _ in
            if rows.count == 1 {
                drawRow(rows[0], x0: pad, top: 0, height: H, font: font, cellW: cellW, segW: segW)
            } else {
                let gap: CGFloat = 1.2
                let rh = (H - gap) / 2
                drawRow(rows[0], x0: pad, top: H - rh, height: rh, font: font, cellW: cellW, segW: segW)  // Claude on top
                drawRow(rows[1], x0: pad, top: 0, height: rh, font: font, cellW: cellW, segW: segW)       // Codex below
            }
            return true
        }

        DispatchQueue.main.async {
            guard let button = self.statusItem.button else { return }
            button.attributedTitle = NSAttributedString()
            button.image = image
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
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
        menu.autoenablesItems = false

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
            let ageNote = scopedStale ? "  (\(ageString(scopedAge ?? 0)) old)" : ""
            scItem.attributedTitle = coloredMenuItem(
                "7d \(scopedLabel ?? "Fable")  \(scStr)  resets \(timeUntil(scopedSevenDayReset))\(ageNote)",
                pct: scPct ?? 0,
                hasData: scPct != nil,
                dim: isStale || scProj || scopedStale)
            scItem.isEnabled = false
            menu.addItem(scItem)
        }

        // Codex rows, whenever a Codex credential exists on this Mac.
        if codexStatus != nil {
            let dim = codexStale
            let cf = codexFiveHour.map { String(format: "%.1f%%", $0) } ?? "N/A"
            let cfItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            cfItem.attributedTitle = coloredMenuItem(
                "Codex 5h  \(cf)  resets \(timeUntil(codexFiveHourReset))",
                pct: codexFiveHour ?? 0, hasData: codexFiveHour != nil, dim: dim)
            cfItem.isEnabled = false
            menu.addItem(cfItem)
            let cs = codexSevenDay.map { String(format: "%.1f%%", $0) } ?? "N/A"
            let csItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            csItem.attributedTitle = coloredMenuItem(
                "Codex 7d  \(cs)  resets \(timeUntil(codexSevenDayReset))",
                pct: codexSevenDay ?? 0, hasData: codexSevenDay != nil, dim: dim)
            csItem.isEnabled = false
            menu.addItem(csItem)
            if codexStatus == "expired" {
                let hint = NSMenuItem(title: "Codex token expired, run `codex login`", action: nil, keyEquivalent: "")
                hint.isEnabled = false
                menu.addItem(hint)
            }
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

        menu.addItem(NSMenuItem.separator())
        let choices: [(String, BarVendors)] = [("Bar: Claude", .claude), ("Bar: Codex", .codex), ("Bar: Claude + Codex", .both)]
        for (title, mode) in choices {
            let item = NSMenuItem(title: title, action: #selector(setVendors(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = barVendors == mode ? .on : .off
            item.isEnabled = mode == .claude || codexStatus != nil
            menu.addItem(item)
        }

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

    @objc func setVendors(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String {
            UserDefaults.standard.set(raw, forKey: barVendorsKey)
        }
        buildMenu()
        updateTitle()
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
        runUpdater(force: true)
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
