import Foundation

enum LyricsParser {
    static func timedLines(from lrc: String) -> [TimedLyric] {
        guard let expression = try? NSRegularExpression(pattern: #"\[(\d{1,2}):(\d{2})(?:\.(\d{1,3}))?\]"#) else { return [] }
        var lines: [TimedLyric] = []
        for rawLine in lrc.components(separatedBy: .newlines) {
            let nsLine = rawLine as NSString
            let matches = expression.matches(in: rawLine, range: NSRange(location: 0, length: nsLine.length))
            guard !matches.isEmpty, let last = matches.last else { continue }
            let text = nsLine.substring(from: NSMaxRange(last.range)).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            for match in matches {
                guard let minuteRange = Range(match.range(at: 1), in: rawLine),
                      let secondRange = Range(match.range(at: 2), in: rawLine),
                      let minutes = Double(rawLine[minuteRange]),
                      let seconds = Double(rawLine[secondRange]) else { continue }
                let fraction: Double
                if let fractionRange = Range(match.range(at: 3), in: rawLine) {
                    let digits = String(rawLine[fractionRange])
                    fraction = (Double(digits) ?? 0) / pow(10, Double(digits.count))
                } else { fraction = 0 }
                lines.append(TimedLyric(time: minutes * 60 + seconds + fraction, text: text))
            }
        }
        return lines.sorted { $0.time < $1.time }
    }

    static func activeLine(in lines: [TimedLyric], at time: Double) -> Int? {
        guard time.isFinite, let index = lines.lastIndex(where: { $0.time <= max(0, time) }) else { return nil }
        return index
    }
}
