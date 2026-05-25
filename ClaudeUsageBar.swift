import Cocoa
import Foundation

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var fiveHour: Double?
    var sevenDay: Double?
    var fiveHourReset: Date?
    var sevenDayReset: Date?
    var lastUpdate: Date?
    var fetchError: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        refreshData()
        buildMenu()

        // Refresh every 60s (makes a lightweight API call)
        Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            self?.refreshData()
            self?.buildMenu()
        }
    }

    // Green (0%) → Yellow (50%) → Red (100%)
    // `darkened` knocks brightness down for readability on light menu backgrounds.
    func colorForPercent(_ pct: Double, darkened: Bool = false) -> NSColor {
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
        return NSColor(red: r * scale, green: g * scale, blue: 0, alpha: 1)
    }

    // Reads OAuth token from a plain file maintained by Claude Code hooks
    // (~/.claude/usage-bar/refresh-token.sh on SessionStart;
    // update-rate-limits.sh refreshes on 401). Avoids macOS keychain
    // prompts on ad-hoc signed apps.
    func getOAuthToken() -> String? {
        let path = NSString(string: "~/.claude/usage-bar/api-token").expandingTildeInPath
        guard let token = try? String(contentsOfFile: path, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            return nil
        }
        return token
    }

    func refreshData() {
        guard let token = getOAuthToken() else {
            fetchError = "No auth token"
            updateTitle(nil, nil)
            return
        }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        // OAuth subscription tokens require Bearer auth + oauth beta header.
        // x-api-key is for API keys only and will return 401 for sk-ant-oat-* tokens.
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 1,
            "messages": [["role": "user", "content": "x"]]
        ])

        let sem = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            defer { sem.signal() }
            guard let self = self else { return }

            if let error = error {
                self.fetchError = error.localizedDescription
                return
            }

            guard let http = response as? HTTPURLResponse else {
                self.fetchError = "Bad response"
                self.fiveHour = nil; self.sevenDay = nil
                return
            }

            // Anything non-200 means we cannot trust the headers. Blank values
            // so the menu shows "--" instead of silently displaying stale
            // numbers (the API returns no ratelimit headers on 401, etc).
            guard http.statusCode == 200 else {
                self.fetchError = "HTTP \(http.statusCode)"
                self.fiveHour = nil; self.sevenDay = nil
                self.fiveHourReset = nil; self.sevenDayReset = nil
                return
            }

            self.fetchError = nil
            self.lastUpdate = Date()

            if let fh = http.value(forHTTPHeaderField: "anthropic-ratelimit-unified-5h-utilization"),
               let val = Double(fh) {
                self.fiveHour = val * 100.0
            }
            if let sd = http.value(forHTTPHeaderField: "anthropic-ratelimit-unified-7d-utilization"),
               let val = Double(sd) {
                self.sevenDay = val * 100.0
            }
            if let r = http.value(forHTTPHeaderField: "anthropic-ratelimit-unified-5h-reset"),
               let ts = Double(r) {
                self.fiveHourReset = Date(timeIntervalSince1970: ts)
            }
            if let r = http.value(forHTTPHeaderField: "anthropic-ratelimit-unified-7d-reset"),
               let ts = Double(r) {
                self.sevenDayReset = Date(timeIntervalSince1970: ts)
            }
        }
        task.resume()
        sem.wait()

        updateTitle(fiveHour, sevenDay)

        // Also write to file for statusline compat
        let cache: [String: Any] = [
            "five_hour": fiveHour as Any,
            "seven_day": sevenDay as Any,
            "timestamp": Date().timeIntervalSince1970
        ]
        if let data = try? JSONSerialization.data(withJSONObject: cache) {
            let path = NSString(string: "~/.claude/rate-limits.json").expandingTildeInPath
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    func updateTitle(_ fh: Double?, _ sd: Double?) {
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        let sepAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]

        let result = NSMutableAttributedString()

        let fhVal = fh ?? 0
        let fhStr = fh.map { String(format: "%.0f", $0) } ?? "--"
        let fhAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: fh != nil ? colorForPercent(fhVal) : NSColor.tertiaryLabelColor
        ]
        result.append(NSAttributedString(string: fhStr, attributes: fhAttrs))
        result.append(NSAttributedString(string: "|", attributes: sepAttrs))

        let sdVal = sd ?? 0
        let sdStr = sd.map { String(format: "%.0f", $0) } ?? "--"
        let sdAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: sd != nil ? colorForPercent(sdVal) : NSColor.tertiaryLabelColor
        ]
        result.append(NSAttributedString(string: sdStr, attributes: sdAttrs))

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

        let fhPct = fiveHour ?? 0
        let fhStr = fiveHour.map { String(format: "%.1f%%", $0) } ?? "N/A"
        let fhItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        fhItem.attributedTitle = coloredMenuItem("5h   \(fhStr)  resets \(timeUntil(fiveHourReset))", pct: fhPct, hasData: fiveHour != nil)
        fhItem.isEnabled = false
        menu.addItem(fhItem)

        let sdPct = sevenDay ?? 0
        let sdStr = sevenDay.map { String(format: "%.1f%%", $0) } ?? "N/A"
        let sdItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        sdItem.attributedTitle = coloredMenuItem("7d   \(sdStr)  resets \(timeUntil(sevenDayReset))", pct: sdPct, hasData: sevenDay != nil)
        sdItem.isEnabled = false
        menu.addItem(sdItem)

        if let lu = lastUpdate {
            let fmt = DateFormatter()
            fmt.dateFormat = "HH:mm:ss"
            menu.addItem(NSMenuItem.separator())
            let luItem = NSMenuItem(title: "updated \(fmt.string(from: lu))", action: nil, keyEquivalent: "")
            luItem.isEnabled = false
            menu.addItem(luItem)
        }

        if let err = fetchError {
            menu.addItem(NSMenuItem.separator())
            let errItem = NSMenuItem(title: "Error: \(err)", action: nil, keyEquivalent: "")
            errItem.isEnabled = false
            menu.addItem(errItem)
        }

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
