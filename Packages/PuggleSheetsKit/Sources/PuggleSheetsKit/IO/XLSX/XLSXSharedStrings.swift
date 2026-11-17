import Foundation

/// Streams xl/sharedStrings.xml. Rich-text runs are joined into plain text; phonetic guides (`<rPh>`)
/// are skipped.
final class XLSXSharedStringsParser: NSObject, XMLParserDelegate {
    private(set) var strings: [String] = []
    /// Set when some string has formatting runs, which are lost.
    private(set) var hasRichText = false

    private var inItem = false
    private var phoneticDepth = 0
    private var inText = false
    private var preservesSpace = false
    private var item = ""
    private var text = ""

    static func parse(_ data: Data) throws -> (strings: [String], hasRichText: Bool) {
        let parser = XLSXSharedStringsParser()
        guard XMLParsing.parse(data, delegate: parser) else { throw MalformedXMLError() }
        return (parser.strings, parser.hasRichText)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch elementName {
        case "si":
            inItem = true
            item = ""
        case "t":
            guard inItem, phoneticDepth == 0 else { return }
            inText = true
            text = ""
            preservesSpace = attributeDict["xml:space"] == "preserve"
        case "r":
            if inItem, phoneticDepth == 0 { hasRichText = true }
        case "rPh":
            phoneticDepth += 1
        default:
            if let local = XMLParsing.strippingPrefix(elementName) {
                self.parser(parser, didStartElement: local, namespaceURI: namespaceURI, qualifiedName: qName, attributes: attributeDict)
            }
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "t":
            guard inText else { return }
            inText = false
            item += preservesSpace ? text : XLSXText.trimmingXMLWhitespace(text)
        case "rPh":
            phoneticDepth = max(0, phoneticDepth - 1)
        case "si":
            guard inItem else { return }
            inItem = false
            strings.append(XLSXText.decode(item))
        default:
            if let local = XMLParsing.strippingPrefix(elementName) {
                self.parser(parser, didEndElement: local, namespaceURI: namespaceURI, qualifiedName: qName)
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { text += string }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if inText { text += String(decoding: CDATABlock, as: UTF8.self) }
    }

    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
        parser.abortParsing()
    }

    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) {
        parser.abortParsing()
    }
}
