import Foundation

/// Zeit- und Textformate im Stil von Apple Podcasts
enum Fmt {
    /// „1 Std. 12 Min.“ / „45 Min.“
    static func duration(_ t: TimeInterval) -> String {
        guard t > 0 else { return "" }
        let f = DateComponentsFormatter()
        f.unitsStyle = .short
        f.allowedUnits = t >= 3600 ? [.hour, .minute] : [.minute]
        f.zeroFormattingBehavior = .dropAll
        return f.string(from: max(60, t)) ?? ""
    }

    /// „Noch 12 Min.“
    static func remaining(_ t: TimeInterval) -> String {
        String(localized: "Noch \(duration(t))")
    }

    /// Uhr-Format für den Player: 1:02:03 bzw. 2:03
    static func clock(_ t: TimeInterval) -> String {
        guard t.isFinite else { return "0:00" }
        let s = Int(max(0, t).rounded(.down))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// Datum wie in Apples Folgenliste: „Heute“, „Gestern“, „Mo.“, „12. Okt.“, „12.10.2023“
    static func date(_ d: Date?) -> String {
        guard let d else { return "" }
        let cal = Calendar.current
        if cal.isDateInToday(d) { return String(localized: "Heute") }
        if cal.isDateInYesterday(d) { return String(localized: "Gestern") }
        let days = cal.dateComponents([.day], from: d, to: .now).day ?? 99
        if days < 7 { return d.formatted(.dateTime.weekday(.wide)) }
        if cal.isDate(d, equalTo: .now, toGranularity: .year) { return d.formatted(.dateTime.day().month(.abbreviated)) }
        return d.formatted(date: .numeric, time: .omitted)
    }

    /// Zeile unter einem Folgentitel: Restzeit oder Dauer
    static func episodeMeta(_ e: Episode) -> String {
        if e.completed { return String(localized: "Gespielt") }
        if e.isInProgress, e.duration > 0 { return remaining(e.remaining) }
        return duration(e.duration)
    }
}

/// HTML-Shownotes in schlichten Text bzw. AttributedString umwandeln
enum ShowNotes {
    /// Schneller Klartext für Listen (ohne WebKit)
    static func plain(_ html: String) -> String {
        var s = html
        for (a, b) in [("<br>", "\n"), ("<br/>", "\n"), ("<br />", "\n"), ("</p>", "\n\n"), ("</li>", "\n"), ("<li>", "• "),
                       ("</h1>", "\n"), ("</h2>", "\n"), ("</h3>", "\n"), ("</h4>", "\n"), ("</div>", "\n")] {
            s = s.replacingOccurrences(of: a, with: b, options: .caseInsensitive)
        }
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        s = decodeEntities(s)
        s = s.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\n\\s*\\n\\s*\\n+", with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decodeEntities(_ s: String) -> String {
        var out = s
        let map = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'",
                   "&rarr;": "→", "&larr;": "←", "&mdash;": "—", "&ndash;": "–", "&hellip;": "…", "&rsquo;": "’", "&lsquo;": "‘",
                   "&rdquo;": "”", "&ldquo;": "“", "&auml;": "ä", "&ouml;": "ö", "&uuml;": "ü", "&Auml;": "Ä", "&Ouml;": "Ö",
                   "&Uuml;": "Ü", "&szlig;": "ß", "&eacute;": "é"]
        for (k, v) in map { out = out.replacingOccurrences(of: k, with: v) }
        // numerische Entities
        let re = try! NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);")
        let ns = out as NSString
        var result = ""
        var last = 0
        for m in re.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let hex = ns.substring(with: m.range(at: 1)) == "x"
            let num = ns.substring(with: m.range(at: 2))
            if let v = UInt32(num, radix: hex ? 16 : 10), let u = Unicode.Scalar(v) { result.append(Character(u)) }
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    /// Zeitmarken (1:02:03 / 12:34) in den Shownotes finden (Analyse #15 „Ab Zeitmarke wiedergeben“)
    static func timestamps(in text: String) -> [(range: Range<String.Index>, seconds: TimeInterval)] {
        // NSRegularExpression, weil Swift-Regex keine Lookbehinds kann
        guard let re = try? NSRegularExpression(pattern: #"(?<![\d:])(\d{1,2}:)?\d{1,2}:\d{2}(?![\d:])"#) else { return [] }
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { m in
            guard let r = Range(m.range, in: text) else { return nil }
            let parts = text[r].split(separator: ":").compactMap { Double($0) }
            guard parts.count >= 2, parts.last! < 60 else { return nil }
            return (r, parts.reduce(0) { $0 * 60 + $1 })
        }
    }

    /// Shownotes als AttributedString mit tippbaren Links und Zeitmarken (`homecast://seek?t=…`)
    static func attributed(_ html: String) -> AttributedString {
        // <a href> erhalten: vor dem Entfernen der Tags durch Marker ersetzen
        let marked = html.replacingOccurrences(of: #"<a\s[^>]*href\s*=\s*["']([^"']+)["'][^>]*>"#, with: "\u{E000}$1\u{E001}",
                                               options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "</a>", with: "\u{E002}", options: .caseInsensitive)
        var raw = plain(marked)
        var links: [(NSRange, URL)] = []
        while let s = raw.range(of: "\u{E000}"), let m = raw.range(of: "\u{E001}", range: s.upperBound..<raw.endIndex) {
            let href = String(raw[s.upperBound..<m.lowerBound])
            let end = raw.range(of: "\u{E002}", range: m.upperBound..<raw.endIndex)
            let label = String(raw[m.upperBound..<(end?.lowerBound ?? raw.endIndex)])
            let loc = raw.distance(from: raw.startIndex, to: s.lowerBound)
            raw.replaceSubrange(s.lowerBound..<(end?.upperBound ?? raw.endIndex), with: label)
            if let u = URL(string: decodeEntities(href)), u.scheme?.hasPrefix("http") == true {
                links.append((NSRange(location: loc, length: label.count), u))
            }
        }
        let text = raw.replacingOccurrences(of: "\u{E002}", with: "")
        var a = AttributedString(text)
        for (r, u) in links {
            let lo = a.index(a.startIndex, offsetByCharacters: min(r.location, a.characters.count))
            let hi = a.index(lo, offsetByCharacters: min(r.length, a.characters.distance(from: lo, to: a.endIndex)))
            a[lo..<hi].link = u
        }
        for (range, secs) in timestamps(in: text) {
            if let r = Range(range, in: a) {
                a[r].link = URL(string: "homecast://seek?t=\(Int(secs))")
            }
        }
        if let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let ns = text as NSString
            for m in det.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                guard let url = m.url, let sr = Range(m.range, in: text), let r = Range(sr, in: a) else { continue }
                a[r].link = url
            }
        }
        return a
    }
}
