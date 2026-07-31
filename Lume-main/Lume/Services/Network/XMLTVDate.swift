//
//  XMLTVDate.swift
//  Lume
//
//  Parses XMLTV programme timestamps (`YYYYMMDDHHMMSS ±HHMM`).
//
//  `DateFormatter.date(from:)` runs full ICU locale parsing on every call. On a
//  large XMLTV guide (two timestamps per programme, tens of thousands of
//  programmes) that dominates EPG ingest and froze the UI for ~9s right after a
//  playlist sync. The fast path parses the fixed-width canonical timestamp by
//  hand; anything non-standard falls back to the formatter, so results are
//  byte-identical to the previous behaviour.
//

import Foundation

enum XMLTVDate {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMddHHmmss Z"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    static func parse(_ dateString: String?) -> Date? {
        guard let dateString, !dateString.isEmpty else { return nil }
        return fastParse(dateString) ?? formatter.date(from: dateString)
    }

    /// Fast path for the canonical XMLTV timestamp `YYYYMMDDHHMMSS ±HHMM`
    /// (e.g. `20240625203000 +0000`) — the exact shape `formatter` accepts.
    /// Returns nil for any other shape so the formatter handles it, keeping
    /// behaviour identical while avoiding ICU parsing for the >99% case.
    private static func fastParse(_ string: String) -> Date? {
        let bytes = Array(string.utf8)
        // 14 date digits + space + sign + 4 offset digits = 20 bytes exactly.
        guard bytes.count == 20 else { return nil }

        func digits(_ start: Int, _ count: Int) -> Int? {
            var value = 0
            for offset in start ..< (start + count) {
                let byte = bytes[offset]
                guard byte >= 0x30, byte <= 0x39 else { return nil }
                value = value * 10 + Int(byte - 0x30)
            }
            return value
        }

        guard let year = digits(0, 4), let month = digits(4, 2), let day = digits(6, 2),
              let hour = digits(8, 2), let minute = digits(10, 2), let second = digits(12, 2),
              bytes[14] == 0x20 // space
        else { return nil }

        let sign: Int
        switch bytes[15] {
        case 0x2B: sign = 1 // '+'
        case 0x2D: sign = -1 // '-'
        default: return nil
        }
        guard let offsetHours = digits(16, 2), let offsetMinutes = digits(18, 2),
              month >= 1, month <= 12, day >= 1, day <= 31,
              hour < 24, minute < 60, second < 60
        else { return nil }

        let offsetSeconds = sign * (offsetHours * 3600 + offsetMinutes * 60)
        let days = daysFromCivil(year: year, month: month, day: day)
        let epoch = days * 86400 + hour * 3600 + minute * 60 + second - offsetSeconds
        return Date(timeIntervalSince1970: TimeInterval(epoch))
    }

    /// Days from 1970-01-01 to a proleptic-Gregorian date (Howard Hinnant's
    /// `days_from_civil`). Avoids `Calendar`, which is itself locale-aware and
    /// far slower than this arithmetic.
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let adjustedYear = month <= 2 ? year - 1 : year
        let era = (adjustedYear >= 0 ? adjustedYear : adjustedYear - 399) / 400
        let yearOfEra = adjustedYear - era * 400
        let dayOfYear = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }
}
