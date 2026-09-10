import Foundation

/// A string-backed enum that decodes unrecognised server values as `.unknown`
/// instead of failing the whole payload. New enum cases added on the server
/// therefore never break older clients.
///
/// Conforming enums only need to declare their raw cases and an `unknown` case:
///
/// ```swift
/// public enum Difficulty: String, SafeEnum {
///     case easy = "EASY", unknown
/// }
/// ```
public protocol SafeEnum: RawRepresentable, Codable, CaseIterable, Hashable, Sendable where RawValue == String {
    /// The fallback used for values this build does not know about.
    static var unknown: Self { get }
}

extension SafeEnum {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = Self(rawValue: raw) ?? Self.unknown
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// Lenient construction from an arbitrary string (case-insensitive).
    public static func lenient(_ raw: String) -> Self {
        if let exact = Self(rawValue: raw) { return exact }
        let upper = raw.uppercased()
        return Self(rawValue: upper) ?? Self.unknown
    }

    /// `true` when this value is the `.unknown` fallback.
    public var isUnknown: Bool { self == Self.unknown }
}
