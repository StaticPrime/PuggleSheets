import Foundation
import Testing
@testable import PuggleSheetsKit

struct IOXMLTreeTests {
    private static func nested(_ depth: Int) -> Data {
        Data((String(repeating: "<a>", count: depth) + String(repeating: "</a>", count: depth)).utf8)
    }

    @Test func refusesPartsNestedTooDeeplyToFreeSafely() {
        #expect(throws: MalformedXMLError.self) { try XMLTree.parse(Self.nested(50_000)) }
        #expect((try? XMLTree.parse(Self.nested(200))) != nil)
    }

    @Test func streamedSubtreesSkipTooDeepElementsButStayBalanced() {
        let builder = XNodeBuilder(rootName: "row", attributes: [:])
        for _ in 0..<1_000 { builder.start("a", [:]) }
        var finished = false
        for _ in 0..<1_000 { finished = builder.end() }
        #expect(!finished)
        #expect(builder.end())
        #expect(builder.isTooDeep)
        var depth = 0
        var node = builder.root
        while let current = node {
            depth += 1
            node = current.children.first
        }
        #expect(depth == XNodeBuilder.maximumDepth)
    }
}
