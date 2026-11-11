import Foundation
import Security

/// A random ID for one feature, like "GB-7K3Q-…": 160 bits from the system's
/// secure random number generator, written in Crockford base32 (no I, L, O
/// or U, so it reads out and types back without mix-ups) in groups of four.
///
/// The rule for every ID Glideball makes: one per feature, each made
/// separately and kept under that feature's own key, never reused for
/// anything else and never made from anything about the person or the Mac.
/// The opt-in stats use `ShareData.installIDKey`; anything later (a sync ID,
/// say) gets its own `RandomID.make()` and its own key. A server that gets
/// one keeps only its SHA-256, so the ID itself stays with the person.
enum RandomID {
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// A new ID: "GB-" and eight groups of four, 160 bits in all. Nil only
    /// if the system can't give random bytes (it then isn't made at all).
    static func make(prefix: String = "GB") -> String? {
        var bytes = [UInt8](repeating: 0, count: 20)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return format(bytes, prefix: prefix)
    }

    /// 20 bytes as "GB-XXXX-…" (5 bits a character, 32 characters).
    static func format(_ bytes: [UInt8], prefix: String = "GB") -> String {
        var chars: [Character] = []
        var buffer = 0, bits = 0
        for b in bytes {
            buffer = (buffer << 8) | Int(b)
            bits += 8
            while bits >= 5 {
                chars.append(alphabet[(buffer >> (bits - 5)) & 31])
                bits -= 5
            }
            buffer &= (1 << bits) - 1
        }
        if bits > 0 { chars.append(alphabet[(buffer << (5 - bits)) & 31]) }
        let groups = stride(from: 0, to: chars.count, by: 4).map { String(chars[$0..<min($0 + 4, chars.count)]) }
        return ([prefix] + groups).joined(separator: "-")
    }

    /// Whether `s` is an ID in the form `make()` writes.
    static func isValid(_ s: String, prefix: String = "GB") -> Bool {
        s.range(of: "^\(prefix)(-[0-9A-HJKMNP-TV-Z]{4}){8}$", options: .regularExpression) != nil
    }
}
