import Foundation

// The Kotlin importers index strings in UTF-16 code units. The ports work on [UInt16] wherever an offset, a limit or a
// character test must come out the same, and use these helpers instead of Swift's Character semantics.

typealias Units = [UInt16]

func units(_ s: String) -> Units { Array(s.utf16) }

func string(_ u: some Collection<UInt16>) -> String { String(decoding: u, as: UTF16.self) }

/// A BMP character literal as a UTF-16 unit: `ch("<")`.
func ch(_ s: Unicode.Scalar) -> UInt16 { UInt16(s.value) }

/// Kotlin `Char.isWhitespace()`: Character.isWhitespace || Character.isSpaceChar (every Zs/Zl/Zp, NBSP included).
func isKotlinWhitespace(_ u: UInt16) -> Bool {
    switch u {
    case 9...13, 28...32, 0x00A0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000: true
    default: false
    }
}

private func category(_ u: UInt16) -> Unicode.GeneralCategory? {
    Unicode.Scalar(u)?.properties.generalCategory
}

/// Kotlin `Char.isLetter()`.
func isLetter(_ u: UInt16) -> Bool {
    switch category(u) {
    case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: true
    default: false
    }
}

/// Kotlin `Char.isLetterOrDigit()`.
func isLetterOrDigit(_ u: UInt16) -> Bool { isLetter(u) || category(u) == .decimalNumber }

func isLowercase(_ u: UInt16) -> Bool { Unicode.Scalar(u)?.properties.isLowercase ?? false }

func isAsciiDigit(_ u: UInt16) -> Bool { u >= 0x30 && u <= 0x39 }

func isHexDigit(_ u: UInt16) -> Bool {
    isAsciiDigit(u) || (u >= 0x41 && u <= 0x46) || (u >= 0x61 && u <= 0x66)
}

func isAsciiLetter(_ u: UInt16) -> Bool { (u >= 0x41 && u <= 0x5A) || (u >= 0x61 && u <= 0x7A) }

func asciiLower(_ u: UInt16) -> UInt16 { (u >= 0x41 && u <= 0x5A) ? u + 32 : u }

/// Kotlin `String.trim()` (whitespace by `isKotlinWhitespace`).
func kotlinTrim(_ u: some Collection<UInt16>) -> Units {
    var s = u.startIndex
    var e = u.endIndex
    while s < e, isKotlinWhitespace(u[s]) { s = u.index(after: s) }
    while e > s, isKotlinWhitespace(u[u.index(before: e)]) { e = u.index(before: e) }
    return Array(u[s..<e])
}

func isKotlinBlank(_ u: some Collection<UInt16>) -> Bool { u.allSatisfy(isKotlinWhitespace) }

extension Array where Element == UInt16 {
    /// `indexOf(needle, from)`; ASCII `needle`, case folded on both sides when `ignoreCase`.
    func find(_ needle: String, from: Int, ignoreCase: Bool = false) -> Int {
        let n = Array(needle.utf16)
        if n.isEmpty { return Swift.min(Swift.max(from, 0), count) }
        if count < n.count { return -1 }
        var i = Swift.max(from, 0)
        let last = count - n.count
        let first = ignoreCase ? asciiLower(n[0]) : n[0]
        while i <= last {
            let c = ignoreCase ? asciiLower(self[i]) : self[i]
            if c == first, matches(n, at: i, ignoreCase: ignoreCase) { return i }
            i += 1
        }
        return -1
    }

    func find(_ target: UInt16, from: Int) -> Int {
        var i = Swift.max(from, 0)
        while i < count {
            if self[i] == target { return i }
            i += 1
        }
        return -1
    }

    func matches(_ n: Units, at i: Int, ignoreCase: Bool = false) -> Bool {
        if i < 0 || i + n.count > count { return false }
        for k in 0..<n.count {
            let a = self[i + k]
            let b = n[k]
            if ignoreCase ? asciiLower(a) != asciiLower(b) : a != b { return false }
        }
        return true
    }

    func startsWith(_ needle: String, at i: Int, ignoreCase: Bool = false) -> Bool {
        matches(Array(needle.utf16), at: i, ignoreCase: ignoreCase)
    }
}

extension String {
    /// "\r\n" and "\r" become "\n" (done on scalars: Swift treats "\r\n" as one Character).
    var normalizedNewlines: String {
        var out = String.UnicodeScalarView()
        var previousWasCR = false
        for s in unicodeScalars {
            if s == "\r" {
                out.append("\n")
                previousWasCR = true
            } else {
                if !(s == "\n" && previousWasCR) { out.append(s) }
                previousWasCR = false
            }
        }
        return String(out)
    }

    /// `split('\n')`, empty pieces kept.
    var linesKeepingEmpty: [String] {
        unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
    }
}
