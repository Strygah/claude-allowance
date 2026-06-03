import Cocoa
import Foundation

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var fiveHour: Double?
    var sevenDay: Double?
    var fiveHourReset: Date?
    var sevenDayReset: Date?
    var lastUpdate: Date?

    let cacheFile = NSString(string: "~/.claude/rate-limits.json").expandingTildeInPath
    let updaterScript = NSString(string: "~/.claude/usage-bar/update-rate-limits.sh").expandingTildeInPath
    let stalenessThreshold: TimeInterval = 300 // 5 min — when to dim + label "(stale)"
    let refreshInterval: TimeInterval = 45     // trigger a fetch once the cache is older than this
    var updaterRunning = false                 // guard against overlapping spawns

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
        if updaterRunning { return }
        updaterRunning = true
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

    func readCache() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: cacheFile)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            fiveHour = nil; sevenDay = nil
            fiveHourReset = nil; sevenDayReset = nil
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

    func updateTitle() {
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        let dimAlpha: CGFloat = isStale ? 0.5 : 1.0
        let result = NSMutableAttributedString()

        let fhStr = fiveHour.map { String(format: "%.0f", $0) } ?? "--"
        let fhColor = fiveHour != nil
            ? colorForPercent(fiveHour ?? 0, alpha: dimAlpha)
            : NSColor.tertiaryLabelColor
        result.append(NSAttributedString(string: fhStr, attributes: [.font: font, .foregroundColor: fhColor]))

        let sepColor = NSColor.white.withAlphaComponent(dimAlpha)
        result.append(NSAttributedString(string: "|", attributes: [.font: font, .foregroundColor: sepColor]))

        let sdStr = sevenDay.map { String(format: "%.0f", $0) } ?? "--"
        let sdColor = sevenDay != nil
            ? colorForPercent(sevenDay ?? 0, alpha: dimAlpha)
            : NSColor.tertiaryLabelColor
        result.append(NSAttributedString(string: sdStr, attributes: [.font: font, .foregroundColor: sdColor]))

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

        let fhStr = fiveHour.map { String(format: "%.1f%%", $0) } ?? "N/A"
        let fhItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        fhItem.attributedTitle = coloredMenuItem(
            "5h   \(fhStr)  resets \(timeUntil(fiveHourReset))",
            pct: fiveHour ?? 0,
            hasData: fiveHour != nil)
        fhItem.isEnabled = false
        menu.addItem(fhItem)

        let sdStr = sevenDay.map { String(format: "%.1f%%", $0) } ?? "N/A"
        let sdItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        sdItem.attributedTitle = coloredMenuItem(
            "7d   \(sdStr)  resets \(timeUntil(sevenDayReset))",
            pct: sevenDay ?? 0,
            hasData: sevenDay != nil)
        sdItem.isEnabled = false
        menu.addItem(sdItem)

        menu.addItem(NSMenuItem.separator())
        let updatedText: String
        if let lu = lastUpdate {
            let suffix = isStale ? "  (stale)" : ""
            updatedText = "updated \(clockFormatter.string(from: lu))\(suffix)"
        } else {
            updatedText = "no data — run any Claude Code command"
        }
        let luItem = NSMenuItem(title: updatedText, action: nil, keyEquivalent: "")
        luItem.isEnabled = false
        menu.addItem(luItem)

        menu.addItem(NSMenuItem.separator())

        let openItem = NSMenuItem(title: "Usage Page...", action: #selector(openUsage), keyEquivalent: "u")
        openItem.target = self
        menu.addItem(openItem)

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    func coloredMenuItem(_ text: String, pct: Double, hasData: Bool) -> NSAttributedString {
        let color = hasData ? colorForPercent(pct, darkened: true) : NSColor.secondaryLabelColor
        return NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium),
            .foregroundColor: color
        ])
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
