import Foundation

/// Type-erased Codable wrapper for heterogeneous JSON values. Kept from
/// upstream for reading and rewriting `~/.claude.json`.
///
/// `@unchecked Sendable`: the wrapped value is an immutable JSON value
/// (null, Bool, number, String, or arrays and objects of those).
struct AnyCodable: Codable, @unchecked Sendable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { value = NSNull() }
        else if let b = try? container.decode(Bool.self) { value = b }
        else if let i = try? container.decode(Int.self) { value = i }
        else if let d = try? container.decode(Double.self) { value = d }
        else if let s = try? container.decode(String.self) { value = s }
        else if let a = try? container.decode([AnyCodable].self) { value = a }
        else if let o = try? container.decode([String: AnyCodable].self) { value = o }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported type") }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull: try container.encodeNil()
        case let b as Bool: try container.encode(b)
        case let i as Int: try container.encode(i)
        case let d as Double: try container.encode(d)
        case let s as String: try container.encode(s)
        case let a as [AnyCodable]: try container.encode(a)
        case let o as [String: AnyCodable]: try container.encode(o)
        default: throw EncodingError.invalidValue(value, .init(codingPath: [], debugDescription: "Unsupported type"))
        }
    }
}
