// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation

/// Builds the XML bodies the DAV verbs send. One reviewable file, the same
/// idea as `Endpoints.swift`: URL/XML construction never spreads through call
/// sites. Prefixes are fixed (`d`, `card`, `cal`, `oc`) because the recorded
/// Nextcloud traffic uses the same set and a diff against a fixture should
/// read cleanly.
enum DAVRequestBody {
    static func propfind(_ properties: [DAVQualifiedName]) -> Data {
        let props = properties.map { "<\(tag(for: $0))/>" }.joined()
        return body("<d:propfind \(namespaceDeclarations)><d:prop>\(props)</d:prop></d:propfind>")
    }

    /// RFC 6578. An empty `<d:sync-token/>` asks for the initial sync.
    static func syncCollection(token: String?) -> Data {
        let tokenElement = token.map { "<d:sync-token>\(escape($0))</d:sync-token>" } ?? "<d:sync-token/>"
        return body(
            """
            <d:sync-collection \(namespaceDeclarations)>\(tokenElement)<d:sync-level>1</d:sync-level>\
            <d:prop><d:getetag/><d:getcontenttype/></d:prop></d:sync-collection>
            """)
    }

    /// `nc:favorite` rides along so a card fetched this round arrives with its favourite
    /// state (WS-35); the per-pass listing catches toggles that moved no ETag.
    static func addressbookMultiget(hrefs: [String]) -> Data {
        multiget(root: "card:addressbook-multiget", data: "<card:address-data/><nc:favorite/>", hrefs: hrefs)
    }

    static func calendarMultiget(hrefs: [String]) -> Data {
        multiget(root: "cal:calendar-multiget", data: "<cal:calendar-data/>", hrefs: hrefs)
    }

    private static func multiget(root: String, data: String, hrefs: [String]) -> Data {
        let hrefElements = hrefs.map { "<d:href>\(escape($0))</d:href>" }.joined()
        return body(
            """
            <\(root) \(namespaceDeclarations)><d:prop><d:getetag/>\(data)</d:prop>\(hrefElements)</\(root)>
            """)
    }

    /// RFC 5689 extended MKCOL: the resource types and initial properties in
    /// one request, which is the only way sabre creates an addressbook.
    static func mkcolExtended(resourceTypes: [DAVQualifiedName], properties: [DAVProposedProperty]) -> Data {
        let types = (["<d:collection/>"] + resourceTypes.map { "<\(tag(for: $0))/>" }).joined()
        let props = properties.map { "<\(tag(for: $0.name))>\(escape($0.value))</\(tag(for: $0.name))>" }
            .joined()
        return body(
            """
            <d:mkcol \(namespaceDeclarations)><d:set><d:prop>\
            <d:resourcetype>\(types)</d:resourcetype>\(props)</d:prop></d:set></d:mkcol>
            """)
    }

    static func proppatch(set: [DAVProposedProperty], remove: [DAVQualifiedName]) -> Data {
        var inner = ""
        if !set.isEmpty {
            let props = set.map { "<\(tag(for: $0.name))>\(escape($0.value))</\(tag(for: $0.name))>" }
                .joined()
            inner += "<d:set><d:prop>\(props)</d:prop></d:set>"
        }
        if !remove.isEmpty {
            let props = remove.map { "<\(tag(for: $0))/>" }.joined()
            inner += "<d:remove><d:prop>\(props)</d:prop></d:remove>"
        }
        return body("<d:propertyupdate \(namespaceDeclarations)>\(inner)</d:propertyupdate>")
    }

    /// Nextcloud's `oc:share` POST against a collection. The principal is the
    /// `principal:principals/users/<id>` form the sharing plugin expects.
    static func share(principal: String, readOnly: Bool) -> Data {
        let access = readOnly ? "<o:read/>" : "<o:read-write/>"
        return body(
            """
            <o:share xmlns:d="DAV:" xmlns:o="\(DAVQualifiedName.owncloud)">\
            <o:set><d:href>\(escape(principal))</d:href>\(access)</o:set></o:share>
            """)
    }

    // MARK: - Plumbing

    private static let namespaceDeclarations =
        """
        xmlns:d="DAV:" xmlns:card="\(DAVQualifiedName.carddav)" xmlns:cal="\(DAVQualifiedName.caldav)" \
        xmlns:cs="\(DAVQualifiedName.calendarserver)" xmlns:oc="\(DAVQualifiedName.owncloud)" \
        xmlns:nc="\(DAVQualifiedName.nextcloudCom)"
        """

    private static func body(_ xml: String) -> Data {
        Data(("<?xml version=\"1.0\" encoding=\"utf-8\" ?>" + xml).utf8)
    }

    /// The prefixed tag for a qualified name, in the fixed prefix set.
    private static func tag(for name: DAVQualifiedName) -> String {
        let prefix: String
        switch name.namespace {
        case DAVQualifiedName.dav: prefix = "d"
        case DAVQualifiedName.carddav: prefix = "card"
        case DAVQualifiedName.caldav: prefix = "cal"
        case DAVQualifiedName.calendarserver: prefix = "cs"
        case DAVQualifiedName.owncloud: prefix = "oc"
        case DAVQualifiedName.nextcloudCom: prefix = "nc"
        default: prefix = "d"
        }
        return "\(prefix):\(name.name)"
    }

    static func escape(_ text: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            default: escaped.append(character)
            }
        }
        return escaped
    }
}
