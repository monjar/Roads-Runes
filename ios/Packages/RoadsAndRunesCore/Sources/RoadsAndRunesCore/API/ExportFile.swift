import Foundation

/// A file the server made to be handed on (a route as a FIT course, a journey as
/// FIT or GPX), kept on the phone so the share sheet passes the file itself.
/// Sharing the API's URL instead handed other apps a link they could not open
/// without the rider's token.
///
/// Each file sits in a folder of its own under the temporary directory, named as
/// the server named it ("Scenic ride.fit"), because that name is what Garmin
/// Connect, Files and AirDrop show.
public enum ExportFile {
    /// Where exports wait to be shared; the system clears it in time anyway.
    public static var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Exports", isDirectory: true)
    }

    /// The filename in a `Content-Disposition` header, safe to write: `filename*`
    /// (RFC 5987) first, then `filename`, quoted or not. Without one, `fallback`.
    /// A name with no extension takes the fallback's, so a FIT file stays `.fit`.
    public static func filename(contentDisposition header: String?, fallback: String) -> String {
        let parameters = header.map(Self.parameters(of:)) ?? [:]
        let extended = parameters["filename*"].flatMap(Self.decodeExtended)
        guard let raw = extended ?? parameters["filename"] else { return fallback }
        var name = sanitized(raw)
        guard !name.isEmpty else { return fallback }
        let fallbackExtension = (fallback as NSString).pathExtension
        if (name as NSString).pathExtension.isEmpty, !fallbackExtension.isEmpty {
            name += ".\(fallbackExtension)"
        }
        return name
    }

    /// Writes `data` to a fresh folder under `directory` as `name` (made safe first).
    public static func write(_ data: Data, named name: String) throws -> URL {
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let safe = sanitized(name)
        let url = folder.appendingPathComponent(safe.isEmpty ? "export" : safe, isDirectory: false)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Removes an export once it has been shared or given up on: its folder too
    /// when it is one of ours, and nothing outside `directory`.
    public static func discard(_ url: URL?) {
        guard let url else { return }
        let root = directory.resolvingSymlinksInPath().path
        let folder = url.deletingLastPathComponent().resolvingSymlinksInPath()
        guard folder.path.hasPrefix(root + "/") else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Parsing

    /// The header's parameters, names lowercased; quoted values unquoted, with
    /// `\"` read as a quote. An unclosed quote runs to the end.
    static func parameters(of header: String) -> [String: String] {
        var result: [String: String] = [:]
        var rest = Substring(header)
        // The disposition type ("attachment") comes first and has no value.
        guard let firstSemicolon = rest.firstIndex(of: ";") else { return result }
        rest = rest[rest.index(after: firstSemicolon)...]
        while !rest.isEmpty {
            rest = rest.drop { $0 == " " || $0 == "\t" || $0 == ";" }
            guard let equals = rest.firstIndex(of: "=") else { break }
            let name = rest[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            rest = rest[rest.index(after: equals)...].drop { $0 == " " || $0 == "\t" }
            var value = ""
            if rest.first == "\"" {
                rest = rest.dropFirst()
                var escaped = false
                while let character = rest.first {
                    rest = rest.dropFirst()
                    if escaped {
                        value.append(character)
                        escaped = false
                    } else if character == "\\" {
                        escaped = true
                    } else if character == "\"" {
                        break
                    } else {
                        value.append(character)
                    }
                }
                // Whatever trails the closing quote, up to the next parameter.
                if let semicolon = rest.firstIndex(of: ";") { rest = rest[semicolon...] } else { rest = "" }
            } else {
                let end = rest.firstIndex(of: ";") ?? rest.endIndex
                value = rest[..<end].trimmingCharacters(in: .whitespaces)
                rest = rest[end...]
            }
            if !name.isEmpty, result[name] == nil { result[name] = value }
        }
        return result
    }

    /// `UTF-8''Caf%C3%A9.fit` → `Café.fit`.
    static func decodeExtended(_ value: String) -> String? {
        let parts = value.components(separatedBy: "'")
        guard parts.count >= 3 else { return nil }
        return parts[2...].joined(separator: "'").removingPercentEncoding
    }

    /// No folders, no control characters, nothing hidden: a plain file name.
    static func sanitized(_ name: String) -> String {
        let unsafe = CharacterSet(charactersIn: "/\\:").union(.controlCharacters).union(.newlines)
        let kept = String(String.UnicodeScalarView(name.unicodeScalars.filter { !unsafe.contains($0) }))
        let trimmed = kept.trimmingCharacters(in: .whitespaces)
        return String(trimmed.drop { $0 == "." || $0 == " " })
    }
}
