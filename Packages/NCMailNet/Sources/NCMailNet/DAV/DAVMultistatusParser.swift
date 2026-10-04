// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation

/// Parses a `207 Multi-Status` body with Foundation's `XMLParser` — streaming,
/// namespace-aware, and no new dependency (definition of done).
///
/// The grammar it understands is RFC 4918's: `multistatus > response >
/// (href, status | propstat > (prop, status))`, plus RFC 6578's top-level
/// `sync-token`. Properties keep whatever shape they had: text, `href`
/// children, or named child elements.
final class DAVMultistatusParser: NSObject, XMLParserDelegate {
    private var stack: [DAVQualifiedName] = []

    private var responses: [DAVResource] = []
    private var topSyncToken: String?

    // Current response
    private var responseHref: String?
    private var responseStatus: Int?
    private var propstats: [DAVPropstat] = []

    // Current propstat
    private var propstatStatus: Int?
    private var propstatProperties: [DAVQualifiedName: DAVPropertyValue] = [:]

    // Current property inside prop
    private var propertyName: DAVQualifiedName?
    private var propertyDepth = 0
    private var propertyText = ""
    private var propertyHrefs: [String] = []
    private var propertyElements: [DAVElement] = []
    private var insideDirectHref = false

    // Plain text accumulators for href/status/sync-token
    private var textBuffer = ""

    private var parseError: (any Error)?

    static func parse(_ data: Data) throws -> DAVMultistatus {
        let delegate = DAVMultistatusParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        guard parser.parse(), delegate.parseError == nil else {
            throw DAVError.invalidResponse("multistatus XML did not parse")
        }
        return DAVMultistatus(responses: delegate.responses, syncToken: delegate.topSyncToken)
    }

    // MARK: - XMLParserDelegate

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) {
        let name = DAVQualifiedName(namespaceURI ?? "", elementName)
        stack.append(name)
        textBuffer = ""

        let depth = stack.count
        if isDAV(name, "response"), depth == 2 {
            responseHref = nil
            responseStatus = nil
            propstats = []
        } else if isDAV(name, "propstat"), depth == 3 {
            propstatStatus = nil
            propstatProperties = [:]
        } else if propertyName != nil, depth == propertyDepth + 1 {
            // A direct child of the property being captured.
            if isDAV(name, "href") {
                insideDirectHref = true
            } else {
                propertyElements.append(DAVElement(name: name, attributes: attributes))
            }
        } else if propertyName == DAVQualifiedName.currentUserPrivilegeSet, depth == propertyDepth + 2,
            isDAV(stack[stack.count - 2], "privilege")
        {
            // RFC 3744 nests the privilege one level down (`privilege > write`); the
            // privilege's name is the only thing worth keeping, so it is lifted up.
            propertyElements.append(DAVElement(name: name, attributes: attributes))
        } else if stack.count >= 2, propertyName == nil, isInsideProp() {
            // A property element directly inside prop.
            propertyName = name
            propertyDepth = depth
            propertyText = ""
            propertyHrefs = []
            propertyElements = []
            insideDirectHref = false
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        textBuffer += string
        if propertyName != nil, stack.count == propertyDepth {
            propertyText += string
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        let name = DAVQualifiedName(namespaceURI ?? "", elementName)
        let depth = stack.count
        defer { stack.removeLast() }

        if let currentProperty = propertyName {
            if depth == propertyDepth + 1, isDAV(name, "href"), insideDirectHref {
                propertyHrefs.append(textBuffer.trimmingCharacters(in: .whitespacesAndNewlines))
                insideDirectHref = false
                return
            }
            if depth == propertyDepth, name == currentProperty {
                propstatProperties[currentProperty] = resolvedPropertyValue()
                propertyName = nil
                return
            }
            return
        }

        if isDAV(name, "href"), depth == 3 {
            responseHref = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if isDAV(name, "status") {
            let status = DAVMultistatusParser.statusCode(textBuffer)
            if depth == 3 {
                responseStatus = status
            } else if depth == 4 {
                propstatStatus = status
            }
        } else if isDAV(name, "propstat"), depth == 3 {
            propstats.append(DAVPropstat(status: propstatStatus ?? 0, properties: propstatProperties))
        } else if isDAV(name, "response"), depth == 2 {
            responses.append(
                DAVResource(href: responseHref ?? "", status: responseStatus, propstats: propstats))
        } else if isDAV(name, "sync-token"), depth == 2 {
            topSyncToken = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred error: any Error) {
        parseError = error
    }

    // MARK: - Helpers

    private func isDAV(_ name: DAVQualifiedName, _ local: String) -> Bool {
        name.namespace == DAVQualifiedName.dav && name.name == local
    }

    /// True when the element now opening sits directly inside a `prop`.
    private func isInsideProp() -> Bool {
        stack.count >= 2 && isDAV(stack[stack.count - 2], "prop")
    }

    private func resolvedPropertyValue() -> DAVPropertyValue {
        if !propertyHrefs.isEmpty { return .hrefs(propertyHrefs) }
        if !propertyElements.isEmpty { return .elements(propertyElements) }
        // Text kept exactly as parsed: address-data is a whole vCard whose
        // trailing line ending matters. All-whitespace means empty.
        if propertyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .empty }
        return .text(propertyText)
    }

    /// `HTTP/1.1 507 Insufficient Storage` → 507.
    static func statusCode(_ line: String) -> Int {
        let parts = line.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        guard parts.count >= 2, let code = Int(parts[1]) else { return 0 }
        return code
    }
}

/// Parses sabre's `d:error` body: the exception class and its message, which
/// are the only diagnostics the server gives for a 4xx on a DAV route.
final class DAVErrorBodyParser: NSObject, XMLParserDelegate {
    private var stack: [DAVQualifiedName] = []
    private var text = ""
    private(set) var exception: String?
    private(set) var message: String?

    static func parse(_ data: Data) -> (exception: String?, message: String?) {
        guard !data.isEmpty else { return (nil, nil) }
        let delegate = DAVErrorBodyParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        _ = parser.parse()
        return (delegate.exception, delegate.message)
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) {
        stack.append(DAVQualifiedName(namespaceURI ?? "", elementName))
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        defer { stack.removeLast() }
        guard namespaceURI == DAVQualifiedName.sabre else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if elementName == "exception" { exception = value }
        if elementName == "message" { message = value }
    }
}
