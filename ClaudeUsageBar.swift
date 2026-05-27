import Cocoa
import Foundation

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var fiveHour: Double?
    var sevenDay: Double?
    var fiveHourReset: Date?
    var sevenDayReset: Date?
    var lastUpdate: Date?

    let cacheFile = NSString(string: "~/.claude/rate-limits.json").expandingTildeInPath
    let stalenessThreshold: TimeInterval = 300 // 5 minutes

    lazy var clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        readCache()
        buildMenu()

        // Re-read cache every 30s. update-rate-limits.sh (PostToolUse +
        // SessionStart hooks) is the sole writer; this app just renders.
        Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.readCache()
            self?.buildMenu()
        }
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

    var isStale: Bool {
        guard let lu = lastUpdate else { return true }
        return Date().timeIntervalSince(lu) > stalenessThreshold
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
