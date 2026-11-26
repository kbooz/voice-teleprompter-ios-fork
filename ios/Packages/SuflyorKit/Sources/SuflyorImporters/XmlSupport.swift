import Foundation
import SuflyorDomain

/// Attributes of one element with their namespace resolved (what Kotlin's SAX `Attributes.getValue(uri, name)` gives).
struct XmlAttributes {
    fileprivate var items: [(uri: String, local: String, value: String)] = []

    func value(_ uri: String, _ local: String) -> String? {
        items.first { $0.uri == uri && $0.local == local }?.value
    }
}

/// Receives namespace-aware events from `Sax.parse`. May throw an `ImportError`, which stops the parse.
class XmlHandler {
    func start(uri: String, local: String, attrs: XmlAttributes) throws(ImportError) {}
    func end(uri: String, local: String) throws(ImportError) {}
    func text(_ s: String) throws(ImportError) {}
}

/// SAX-style parsing with Foundation's `XMLParser` (port of Kotlin `Sax`). Office XML never contains a DTD, so any DTD
/// is refused up front; that is the defence against entity-expansion attacks ("billion laughs"), and external
/// entities stay off (`shouldResolveExternalEntities` defaults to false).
enum Sax {
    static func parse(_ data: Data, handler: XmlHandler) throws(ImportError) {
        if containsDoctype(data) { throw .unsafeDocument }
        let driver = Driver(handler: handler)
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = driver
        let ok = parser.parse()
        if let failure = driver.failure { throw failure }
        // A document that is not well-formed XML is "damaged" for the user.
        if !ok { throw .unsafeDocument }
    }

    /// `<!DOCTYPE` or `<!ENTITY`, ASCII case-insensitive, anywhere in the file and also in UTF-16 text (NUL between
    /// the characters). The Kotlin version also looked at the first 4 KB only and relied on the parser for the rest;
    /// scanning the whole part is simpler and stricter.
    static func containsDoctype(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        for pattern in ["<!doctype", "<!entity"] {
            let p = Array(pattern.utf8)
            for stride in [1, 2] where scan(bytes, p, stride: stride) { return true }
        }
        return false
    }

    private static func scan(_ bytes: [UInt8], _ p: [UInt8], stride: Int) -> Bool {
        let span = (p.count - 1) * stride + 1
        if bytes.count < span { return false }
        var i = 0
        // `i` also runs over odd offsets, which covers UTF-16 BE (a NUL before each character) as well as LE.
        while i + span <= bytes.count {
            if bytes[i] == 0x3C {
                var k = 1
                while k < p.count {
                    var b = bytes[i + k * stride]
                    if b >= 0x41 && b <= 0x5A { b += 32 }
                    if b != p[k] { break }
                    k += 1
                }
                if k == p.count { return true }
            }
            i += 1
        }
        return false
    }

    private final class Driver: NSObject, XMLParserDelegate {
        let handler: XmlHandler
        var failure: ImportError?
        /// Prefix -> stack of namespace URIs in scope ("" is the default namespace). A lookup is O(1) however deep the
        /// document nests; walking a per-element scope list was quadratic on 100 000 nested levels.
        private var bindings: [String: [String]] = [:]
        /// Prefixes declared by each open element, so they can be popped when it ends.
        private var declared: [[String]] = []

        init(handler: XmlHandler) { self.handler = handler }

        private func resolve(_ prefix: String) -> String {
            bindings[prefix]?.last ?? ""
        }

        private func split(_ qualified: String) -> (prefix: String, local: String) {
            if let colon = qualified.firstIndex(of: ":") {
                return (String(qualified[..<colon]), String(qualified[qualified.index(after: colon)...]))
            }
            return ("", qualified)
        }

        private func fail(_ error: any Error, _ parser: XMLParser) {
            failure = error as? ImportError ?? .unsafeDocument
            parser.abortParsing()
        }

        func parser(
            _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
            qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
        ) {
            if failure != nil { return }
            // Without namespace processing, xmlns declarations arrive as ordinary attributes.
            var prefixes: [String] = []
            for (key, value) in attributeDict {
                if key == "xmlns" {
                    bindings["", default: []].append(value)
                    prefixes.append("")
                } else if key.hasPrefix("xmlns:") {
                    let prefix = String(key.dropFirst(6))
                    bindings[prefix, default: []].append(value)
                    prefixes.append(prefix)
                }
            }
            declared.append(prefixes)
            var attrs = XmlAttributes()
            for (key, value) in attributeDict where key != "xmlns" && !key.hasPrefix("xmlns:") {
                let (prefix, local) = split(key)
                // An unprefixed attribute is in no namespace.
                attrs.items.append((prefix.isEmpty ? "" : resolve(prefix), local, value))
            }
            let (prefix, local) = split(elementName)
            do {
                try handler.start(uri: resolve(prefix), local: local, attrs: attrs)
            } catch {
                fail(error, parser)
            }
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?
        ) {
            if failure != nil { return }
            let (prefix, local) = split(elementName)
            let uri = resolve(prefix)
            do {
                try handler.end(uri: uri, local: local)
            } catch {
                fail(error, parser)
            }
            for prefix in declared.popLast() ?? [] { _ = bindings[prefix]?.popLast() }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if failure != nil { return }
            do {
                try handler.text(string)
            } catch {
                fail(error, parser)
            }
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            self.parser(parser, foundCharacters: String(decoding: CDATABlock, as: UTF8.self))
        }
    }
}
