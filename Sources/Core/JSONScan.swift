import Foundation

public enum JSONScan {
    /// The byte range of `key`'s value in a top-level JSON object, found without re-encoding anything.
    /// Nil when the data is not an object or has no such key. Keys with escapes never match.
    public static func topLevelValue(of key: String, in data: Data) -> Range<Int>? {
        let wanted = Array(key.utf8)
        return data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Range<Int>? in
            var i = 0
            func skipSpace() { while i < bytes.count, [0x20, 0x0A, 0x0D, 0x09].contains(bytes[i]) { i += 1 } }
            /// Leaves `i` after the string's closing quote.
            func skipString() {
                i += 1
                while i < bytes.count, bytes[i] != UInt8(ascii: "\"") { i += bytes[i] == UInt8(ascii: "\\") ? 2 : 1 }
                i += 1
            }
            func skipValue() {
                var depth = 0
                repeat {
                    guard i < bytes.count else { return }
                    switch bytes[i] {
                    case UInt8(ascii: "\""): skipString(); continue
                    case UInt8(ascii: "{"), UInt8(ascii: "["): depth += 1
                    case UInt8(ascii: "}"), UInt8(ascii: "]"):
                        if depth == 0 { return }
                        depth -= 1
                    case UInt8(ascii: ","): if depth == 0 { return }
                    default: break
                    }
                    i += 1
                } while depth > 0 || (i < bytes.count && ![UInt8(ascii: ","), UInt8(ascii: "}")].contains(bytes[i]))
            }
            skipSpace()
            guard i < bytes.count, bytes[i] == UInt8(ascii: "{") else { return nil }
            i += 1
            while true {
                skipSpace()
                guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { return nil }
                let keyStart = i + 1
                skipString()
                let matches = i - 1 - keyStart == wanted.count && i <= bytes.count && bytes[keyStart..<(i - 1)].elementsEqual(wanted)
                skipSpace()
                guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { return nil }
                i += 1
                skipSpace()
                let valueStart = i
                skipValue()
                guard i <= bytes.count else { return nil }
                if matches {
                    var end = i
                    while end > valueStart, [0x20, 0x0A, 0x0D, 0x09].contains(bytes[end - 1]) { end -= 1 }
                    return valueStart..<end
                }
                skipSpace()
                guard i < bytes.count, bytes[i] == UInt8(ascii: ",") else { return nil }
                i += 1
            }
        }
    }
}
