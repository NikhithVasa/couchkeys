import Foundation

struct RokuElement: Sendable {
    let name: String
    let attributes: [String: String]
    let text: String
    let children: [RokuElement]

    func child(_ name: String) -> RokuElement? {
        children.first { $0.name == name }
    }

    func value(_ name: String) -> String? {
        child(name)?.text.nonemptyRokuText
    }
}

extension String {
    var nonemptyRokuText: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

final class RokuXML: NSObject, XMLParserDelegate {
    private struct Draft {
        let name: String
        let attributes: [String: String]
        var text = ""
        var children: [RokuElement] = []
    }

    private var stack: [Draft] = []
    private var root: RokuElement?
    private var failure: String?
    private var elementCount = 0
    private var textBytes = 0

    static func parse(_ data: Data, root expectedRoot: String) throws -> RokuElement {
        guard data.count <= 1_048_576 else {
            throw TVFailure.message("The TV's \(expectedRoot) response exceeds the XML size limit.")
        }
        guard data.range(of: Data("<!DOCTYPE".utf8)) == nil,
              data.range(of: Data("<!ENTITY".utf8)) == nil else {
            throw TVFailure.message("The TV's XML response contains an unsupported document declaration.")
        }
        let delegate = RokuXML()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), delegate.failure == nil,
              let root = delegate.root, root.name == expectedRoot else {
            let detail = delegate.failure ?? parser.parserError?.localizedDescription
                ?? "Expected a \(expectedRoot) root element."
            throw TVFailure.message("Invalid \(expectedRoot) response: \(detail)")
        }
        return root
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String]) {
        elementCount += 1
        guard stack.count < 32, elementCount <= 10_000 else {
            stop(parser, "XML nesting or element count exceeds the safety limit.")
            return
        }
        stack.append(Draft(name: elementName, attributes: attributeDict))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        appendText(string, parser: parser)
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let text = String(data: CDATABlock, encoding: .utf8) else {
            stop(parser, "Invalid UTF-8 CDATA.")
            return
        }
        appendText(text, parser: parser)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        guard let draft = stack.popLast(), draft.name == elementName else {
            stop(parser, "Unbalanced XML elements.")
            return
        }
        let element = RokuElement(name: draft.name, attributes: draft.attributes,
                                  text: draft.text, children: draft.children)
        if stack.isEmpty {
            guard root == nil else {
                stop(parser, "Multiple XML root elements.")
                return
            }
            root = element
        } else {
            stack[stack.count - 1].children.append(element)
        }
    }

    func parser(_ parser: XMLParser, resolveExternalEntityName name: String,
                systemID: String?) -> Data? {
        stop(parser, "External XML entities are not allowed.")
        return nil
    }

    private func appendText(_ text: String, parser: XMLParser) {
        textBytes += text.utf8.count
        guard textBytes <= 1_048_576 else {
            stop(parser, "Expanded XML text exceeds the safety limit.")
            return
        }
        if !stack.isEmpty {
            stack[stack.count - 1].text.append(text)
        }
    }

    private func stop(_ parser: XMLParser, _ message: String) {
        failure = message
        parser.abortParsing()
    }
}
