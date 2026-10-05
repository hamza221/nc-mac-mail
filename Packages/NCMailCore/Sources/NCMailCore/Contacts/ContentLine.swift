// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation

/// One parameter of a directory-format property: `TYPE=WORK,PREF` or a bare
/// vCard-2.1 token like `HOME`.
public struct DirectoryParameter: Sendable, Equatable, Hashable {
    public var name: String
    /// Decoded values: quotes removed, the comma list split. Empty for a bare
    /// 2.1-style token, whose `name` then *is* the value.
    public var values: [String]

    public init(name: String, values: [String]) {
        self.name = name
        self.values = values
    }
}

/// One logical line of a vCard or iCalendar object, parsed but not interpreted.
///
/// Losslessness lives here: `rawLine` is the unfolded original, and the
/// serialiser re-emits it byte for byte (re-folded) for any property this app
/// did not touch. The parsed `group`/`name`/`parameters`/`rawValue` exist for
/// the typed accessors; they never feed back into serialisation of an
/// untouched property, so a parameter shape we half-understand cannot be
/// destroyed by a round trip. Assigning any of them drops `rawLine`, so an
/// edit is never silently discarded in favour of the original. ADR-0075.
public struct DirectoryProperty: Sendable, Equatable {
    public var group: String? { didSet { rawLine = nil } }
    /// As written. Matching is always case-insensitive (`isNamed`).
    public var name: String { didSet { rawLine = nil } }
    public var parameters: [DirectoryParameter] { didSet { rawLine = nil } }
    /// The text after the first unquoted `:`, exactly as written — escapes and
    /// quoted-printable intact. `decodedValue()` interprets it.
    public var rawValue: String { didSet { rawLine = nil } }
    /// The unfolded original line, or nil for a property this app synthesised
    /// or edited.
    public private(set) var rawLine: String?

    /// A synthesised property. `rawLine` stays nil so the serialiser knows to
    /// build the line from the parts.
    public init(group: String? = nil, name: String, parameters: [DirectoryParameter] = [], value: String) {
        self.group = group
        self.name = name
        self.parameters = parameters
        rawValue = value
        rawLine = nil
    }

    init(group: String?, name: String, parameters: [DirectoryParameter], rawValue: String, rawLine: String) {
        self.group = group
        self.name = name
        self.parameters = parameters
        self.rawValue = rawValue
        self.rawLine = rawLine
    }

    public func isNamed(_ name: String) -> Bool {
        self.name.caseInsensitiveCompare(name) == .orderedSame
    }

    /// The first parameter with this name, matched case-insensitively.
    public func parameter(_ name: String) -> DirectoryParameter? {
        parameters.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Every value of every parameter with this name, flattened: `TYPE=WORK;TYPE=VOICE`
    /// and `TYPE=WORK,VOICE` answer the same.
    public func parameterValues(_ name: String) -> [String] {
        parameters.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.flatMap(\.values)
    }

    /// The value with text escapes undone and 2.1-style quoted-printable decoded.
    ///
    /// Escape handling follows RFC 6350 §3.4: `\n`/`\N` to newline, `\,` `\;`
    /// `\\` to the bare character. Unknown escapes keep their backslash, which
    /// is what sabre does too.
    public func decodedValue() -> String {
        var text = rawValue
        if let encoding = parameter("ENCODING")?.values.first,
            encoding.caseInsensitiveCompare("QUOTED-PRINTABLE") == .orderedSame
        {
            text = ContentLine.decodeQuotedPrintable(text, charset: parameter("CHARSET")?.values.first)
        }
        return ContentLine.unescape(text)
    }

    /// The structured value split on unescaped separators — `;` for N/ADR/ORG
    /// components, `,` for CATEGORIES/NICKNAME lists — each component unescaped.
    public func decodedComponents(separator: Character) -> [String] {
        ContentLine.splitUnescaped(rawValue, on: separator).map(ContentLine.unescape)
    }

    /// The line to emit: the untouched original, or one built from the parts.
    public var serializedLine: String {
        if let rawLine { return rawLine }
        var line = ""
        if let group { line += group + "." }
        line += name
        for parameter in parameters {
            line += ";" + parameter.name
            if !parameter.values.isEmpty {
                line += "=" + parameter.values.map(ContentLine.quoteParameterValue).joined(separator: ",")
            }
        }
        line += ":" + rawValue
        return line
    }
}

/// The lexer both formats share: RFC 6350 and RFC 5545 use the same
/// line/fold/parameter grammar, so it is written once and owned here.
enum ContentLine {
    /// Splits physical lines and rejoins folded ones. A continuation line
    /// starts with a space or tab; the fold (CRLF + one blank) disappears.
    /// Bare LF is tolerated because files that crossed a Unix pipe are a fact
    /// of life in imports.
    static func unfold(_ text: String) -> [String] {
        var logical: [String] = []
        var current: String?
        for physical in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if let first = physical.first, first == " " || first == "\t" {
                current = (current ?? "") + physical.dropFirst()
            } else {
                if let line = current, !line.isEmpty { logical.append(line) }
                current = String(physical)
            }
        }
        if let line = current, !line.isEmpty { logical.append(line) }
        return logical
    }

    /// Parses one logical line into its parts. Throws on a line with no `:`
    /// outside quotes, which is the only shape that cannot be a content line.
    static func parse(_ line: String) throws(DirectoryParseError) -> DirectoryProperty {
        var group: String?
        var name = ""
        var parameters: [DirectoryParameter] = []

        var index = line.startIndex
        // group and name: IANA tokens up to '.', ';' or ':'
        var token = ""
        scan: while index < line.endIndex {
            let character = line[index]
            switch character {
            case ".":
                // Only the first '.' before ';'/':' is a group separator.
                if group == nil {
                    group = token
                    token = ""
                } else {
                    token.append(character)
                }
            case ";", ":":
                name = token
                break scan
            default:
                token.append(character)
            }
            index = line.index(after: index)
        }
        guard index < line.endIndex, !name.isEmpty else { throw .noValueSeparator(line) }

        // parameters, honouring quoted values (RFC 6350 §3.3 param-value)
        while line[index] == ";" {
            index = line.index(after: index)
            var parameterName = ""
            while index < line.endIndex, line[index] != "=", line[index] != ";", line[index] != ":" {
                parameterName.append(line[index])
                index = line.index(after: index)
            }
            guard index < line.endIndex else { throw .noValueSeparator(line) }
            if line[index] == "=" {
                index = line.index(after: index)
                var values: [String] = []
                var value = ""
                var quoted = false
                collect: while index < line.endIndex {
                    let character = line[index]
                    switch character {
                    case "\"":
                        quoted.toggle()
                    case "," where !quoted:
                        values.append(value)
                        value = ""
                    case ";" where !quoted, ":" where !quoted:
                        break collect
                    default:
                        value.append(character)
                    }
                    index = line.index(after: index)
                }
                guard index < line.endIndex else { throw .noValueSeparator(line) }
                values.append(value)
                parameters.append(DirectoryParameter(name: parameterName, values: values))
            } else {
                // vCard 2.1 bare token: `TEL;HOME;VOICE:…`
                parameters.append(DirectoryParameter(name: parameterName, values: []))
            }
        }
        // line[index] == ":"
        let rawValue = String(line[line.index(after: index)...])
        return DirectoryProperty(
            group: (group?.isEmpty ?? true) ? nil : group,
            name: name,
            parameters: parameters,
            rawValue: rawValue,
            rawLine: line
        )
    }

    // MARK: - Folding

    /// RFC 6350 §3.2 / RFC 5545 §3.1: emitted lines SHOULD stay within 75
    /// octets, folded with CRLF plus one space. The split lands on a scalar
    /// boundary so a multi-byte character is never torn.
    static func fold(_ line: String, limit: Int = 75) -> String {
        var remaining = Substring(line)
        var pieces: [Substring] = []
        var budget = limit
        while remaining.utf8.count > budget {
            var cut = remaining.startIndex
            var octets = 0
            while cut < remaining.endIndex {
                let next = remaining.index(after: cut)
                let width = remaining[cut..<next].utf8.count
                if octets + width > budget { break }
                octets += width
                cut = next
            }
            // A budget smaller than one scalar: emit the scalar anyway rather
            // than loop forever. Only reachable with a pathological limit.
            if cut == remaining.startIndex { cut = remaining.index(after: cut) }
            pieces.append(remaining[..<cut])
            remaining = remaining[cut...]
            budget = limit - 1  // continuation lines spend one octet on the leading space
        }
        pieces.append(remaining)
        return pieces.enumerated().map { $0.offset == 0 ? String($0.element) : " " + $0.element }
            .joined(separator: "\r\n")
    }

    // MARK: - Text escapes

    static func unescape(_ text: String) -> String {
        guard text.contains("\\") else { return text }
        var result = ""
        result.reserveCapacity(text.count)
        var escaped = false
        for character in text {
            if escaped {
                switch character {
                case "n", "N": result.append("\n")
                case ",", ";", "\\": result.append(character)
                default:
                    // An escape we do not know: keep it whole, as sabre does.
                    result.append("\\")
                    result.append(character)
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                result.append(character)
            }
        }
        if escaped { result.append("\\") }
        return result
    }

    static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "\\": result.append("\\\\")
            case ",": result.append("\\,")
            case ";": result.append("\\;")
            case "\n": result.append("\\n")
            case "\r": continue
            default: result.append(character)
            }
        }
        return result
    }

    static func splitUnescaped(_ text: String, on separator: Character) -> [String] {
        var components: [String] = []
        var current = ""
        var escaped = false
        for character in text {
            if escaped {
                current.append("\\")
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == separator {
                components.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        components.append(current)
        return components
    }

    /// A parameter value that needs quoting gets it; a DQUOTE inside one cannot
    /// be represented in this grammar and is dropped (RFC 6868 caret encoding
    /// is deliberately out of scope — see the WS-17 report).
    static func quoteParameterValue(_ value: String) -> String {
        let cleaned = value.replacingOccurrences(of: "\"", with: "")
        if cleaned.contains(where: { $0 == ";" || $0 == "," || $0 == ":" }) {
            return "\"\(cleaned)\""
        }
        return cleaned
    }

    // MARK: - Quoted-printable (vCard 2.1 imports)

    /// Decodes `=XX` sequences. The charset parameter decides how the decoded
    /// bytes become text; UTF-8 first, Latin-1 as the fallback that cannot fail.
    static func decodeQuotedPrintable(_ text: String, charset: String?) -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(text.utf8.count)
        var iterator = text.utf8.makeIterator()
        var pending: [UInt8] = []
        while let byte = pending.isEmpty ? iterator.next() : pending.removeFirst() {
            if byte == UInt8(ascii: "=") {
                guard let high = iterator.next() else { break }
                guard let low = iterator.next() else {
                    bytes.append(byte)
                    bytes.append(high)
                    break
                }
                if let value = hexValue(high, low) {
                    bytes.append(value)
                } else {
                    bytes.append(byte)
                    pending = [high, low]
                }
            } else {
                bytes.append(byte)
            }
        }
        let data = Data(bytes)
        if let charset, charset.caseInsensitiveCompare("UTF-8") != .orderedSame {
            // Anything that is not UTF-8 is treated as Latin-1: the 2.1 cards
            // seen in the wild are either, and Latin-1 decoding cannot fail.
            return String(data: data, encoding: .isoLatin1) ?? ""
        }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
    }

    private static func hexValue(_ high: UInt8, _ low: UInt8) -> UInt8? {
        func digit(_ byte: UInt8) -> UInt8? {
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
            case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
            case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
            default: nil
            }
        }
        guard let highValue = digit(high), let lowValue = digit(low) else { return nil }
        return highValue << 4 | lowValue
    }
}

/// What can be wrong with a vCard or iCalendar stream, structurally.
public enum DirectoryParseError: Error, Sendable, Equatable {
    /// A line with no `:` outside quotes — not a content line at all.
    case noValueSeparator(String)
    /// Text that never opened a `BEGIN:` for the expected component.
    case missingBegin(expected: String)
    /// A `BEGIN:` whose `END:` never came.
    case unterminated(component: String)
    /// An `END:` that does not match the open component.
    case mismatchedEnd(expected: String, found: String)
}
