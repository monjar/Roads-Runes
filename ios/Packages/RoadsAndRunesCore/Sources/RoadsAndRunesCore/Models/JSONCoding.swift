import Foundation

/// Shared JSON coders configured for the Roads & Runes API: `camelCase` keys
/// are used as-is (`.useDefaultKeys`) and dates are ISO 8601 with or without
/// fractional seconds.
public enum JSONCoding {
    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .useDefaultKeys
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = ISO8601.parse(raw) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unrecognised ISO 8601 date: \(raw)"
            )
        }
        return decoder
    }

    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .useDefaultKeys
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ISO8601.string(from: date))
        }
        return encoder
    }

    /// Decode a value from `Data` using the shared configuration.
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try makeDecoder().decode(type, from: data)
    }

    /// Decode a value from a JSON string (handy in tests and previews).
    public static func decode<T: Decodable>(_ type: T.Type, json: String) throws -> T {
        try makeDecoder().decode(type, from: Data(json.utf8))
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try makeEncoder().encode(value)
    }
}

/// Pure-Swift ISO 8601 parsing/formatting so behaviour is identical on Apple
/// platforms and Linux (and so any number of fractional-second digits works).
public enum ISO8601 {
    /// Parses `YYYY-MM-DD`, `YYYY-MM-DDTHH:MM[:SS[.fff…]][Z|±HH[:MM]]`.
    /// A missing timezone is treated as UTC.
    public static func parse(_ input: String) -> Date? {
        let scalars = Array(input.trimmingCharacters(in: .whitespaces).utf8)
        var index = 0

        func digits(_ count: Int) -> Int? {
            guard index + count <= scalars.count else { return nil }
            var value = 0
            for offset in 0..<count {
                let byte = scalars[index + offset]
                guard byte >= 48, byte <= 57 else { return nil }
                value = value * 10 + Int(byte - 48)
            }
            index += count
            return value
        }

        func consume(_ byte: UInt8) -> Bool {
            guard index < scalars.count, scalars[index] == byte else { return false }
            index += 1
            return true
        }

        guard let year = digits(4), consume(45), let month = digits(2), consume(45), let day = digits(2) else {
            return nil
        }
        guard month >= 1, month <= 12, day >= 1, day <= 31 else { return nil }

        var hour = 0, minute = 0, second = 0
        var fraction = 0.0
        var offsetSeconds = 0

        if consume(84) || consume(116) || consume(32) { // 'T', 't' or ' '
            guard let h = digits(2), consume(58), let m = digits(2) else { return nil }
            hour = h
            minute = m
            if consume(58) {
                guard let s = digits(2) else { return nil }
                second = s
                if consume(46) || consume(44) { // '.' or ','
                    var scale = 0.1
                    var sawDigit = false
                    while index < scalars.count, scalars[index] >= 48, scalars[index] <= 57 {
                        fraction += Double(scalars[index] - 48) * scale
                        scale /= 10
                        index += 1
                        sawDigit = true
                    }
                    guard sawDigit else { return nil }
                }
            }
            if consume(90) || consume(122) { // 'Z' / 'z'
                offsetSeconds = 0
            } else if index < scalars.count, scalars[index] == 43 || scalars[index] == 45 { // '+' / '-'
                let sign = scalars[index] == 45 ? -1 : 1
                index += 1
                guard let oh = digits(2) else { return nil }
                var om = 0
                if consume(58) {
                    guard let m2 = digits(2) else { return nil }
                    om = m2
                } else if let m2 = digits(2) {
                    om = m2
                }
                offsetSeconds = sign * (oh * 3600 + om * 60)
            }
        }
        guard index == scalars.count else { return nil }
        guard hour < 24, minute < 60, second < 61 else { return nil }

        let days = daysFromCivil(year: year, month: month, day: day)
        let seconds = Double(days) * 86_400 + Double(hour * 3600 + minute * 60 + second) + fraction
        return Date(timeIntervalSince1970: seconds - Double(offsetSeconds))
    }

    /// Formats a date as `YYYY-MM-DDTHH:MM:SS.sssZ` (UTC, millisecond precision).
    public static func string(from date: Date) -> String {
        let total = date.timeIntervalSince1970
        let wholeSeconds = total.rounded(.down)
        let millis = Int(((total - wholeSeconds) * 1000).rounded(.down))
        let secondsSinceEpoch = Int(wholeSeconds)
        let days = Int((Double(secondsSinceEpoch) / 86_400).rounded(.down))
        let secondOfDay = secondsSinceEpoch - days * 86_400
        let (year, month, day) = civilFromDays(days)
        let hour = secondOfDay / 3600
        let minute = (secondOfDay % 3600) / 60
        let second = secondOfDay % 60
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ", year, month, day, hour, minute, second, millis)
    }

    // Howard Hinnant's civil calendar algorithms (proleptic Gregorian).
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    static func civilFromDays(_ days: Int) -> (Int, Int, Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (m <= 2 ? y + 1 : y, m, d)
    }
}
