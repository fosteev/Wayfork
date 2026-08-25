import Foundation

/// RFC 3492 Punycode encoder, used to turn IDN labels into their `xn--` form.
enum Punycode {
    private static let base = 36
    private static let tMin = 1
    private static let tMax = 26
    private static let skew = 38
    private static let damp = 700
    private static let initialBias = 72
    private static let initialN = 128

    /// Encodes one label. Returns nil on overflow (labels far beyond DNS limits).
    static func encode(_ label: String) -> String? {
        let input = label.unicodeScalars.map { Int($0.value) }
        var output = input.filter { $0 < 0x80 }.map { Character(Unicode.Scalar(UInt8($0))) }
        let basicCount = output.count
        var handled = basicCount
        if basicCount > 0 {
            output.append("-")
        }

        var n = initialN
        var delta = 0
        var bias = initialBias

        while handled < input.count {
            guard let m = input.filter({ $0 >= n }).min() else { return nil }
            let (product, overflow) = (m - n).multipliedReportingOverflow(by: handled + 1)
            guard !overflow else { return nil }
            delta += product
            n = m
            for c in input {
                if c < n {
                    delta += 1
                }
                guard c == n else { continue }
                var q = delta
                var k = base
                while true {
                    let t = k <= bias ? tMin : (k >= bias + tMax ? tMax : k - bias)
                    if q < t { break }
                    output.append(digit(t + (q - t) % (base - t)))
                    q = (q - t) / (base - t)
                    k += base
                }
                output.append(digit(q))
                bias = adapt(delta: delta, numPoints: handled + 1, firstTime: handled == basicCount)
                delta = 0
                handled += 1
            }
            delta += 1
            n += 1
        }
        return String(output)
    }

    /// `xn--` form of a label, or the label itself when it is pure ASCII.
    static func toASCII(_ label: String) -> String? {
        if label.unicodeScalars.allSatisfy({ $0.isASCII }) {
            return label
        }
        guard let encoded = encode(label) else { return nil }
        return "xn--" + encoded
    }

    private static func digit(_ d: Int) -> Character {
        d < 26 ? Character(Unicode.Scalar(UInt8(97 + d))) : Character(Unicode.Scalar(UInt8(22 + d)))
    }

    private static func adapt(delta: Int, numPoints: Int, firstTime: Bool) -> Int {
        var delta = firstTime ? delta / damp : delta / 2
        delta += delta / numPoints
        var k = 0
        while delta > ((base - tMin) * tMax) / 2 {
            delta /= base - tMin
            k += base
        }
        return k + (base - tMin + 1) * delta / (delta + skew)
    }
}
