import Foundation

/// Reads a sheet's drawing part: pictures and charts become floating objects; pictures PuggleSheets
/// wrote for in-cell images go back into their cells.
enum XLSXDrawingReader {
    /// A slicer's frame: where it sits among the objects, its name (which the sheet's slicer part
    /// explains) and its place.
    struct SlicerFrame {
        var position: Int
        var name: String
        var anchor: ObjectAnchor
        var title: String
        var description: String
    }

    struct Result {
        var objects: [SheetObject] = []
        var slicerFrames: [SlicerFrame] = []
        var cellImages: [CellAddress: CellImage] = [:]
        var warnings: Set<ImportWarning> = []
        /// The furthest row and column an object reaches into, so the grid can grow to hold it.
        var lastRow = -1
        var lastColumn = -1
    }

    static let chartURI = "http://schemas.openxmlformats.org/drawingml/2006/chart"

    static func read(_ path: String, zip: ZipReader, sheet: Sheet, charts: XLSXChartReader.Context) -> Result {
        var result = Result()
        guard let data = try? zip.read(path), let root = try? XMLTree.parse(data) else {
            result.warnings.insert(.images)
            return result
        }
        let relationships = (try? XLSXPackage.relationships(of: path, in: zip)) ?? []
        var byID: [String: XLSXRelationship] = [:]
        for relationship in relationships where byID[relationship.id] == nil { byID[relationship.id] = relationship }
        let reader = AnchorReader(zip: zip, grid: XLSXSheetGrid(sheet: sheet), relationships: byID, charts: charts)
        for node in root.children {
            reader.readAnchor(node, into: &result)
        }
        return result
    }

    private struct AnchorReader {
        let zip: ZipReader
        let grid: XLSXSheetGrid
        let relationships: [String: XLSXRelationship]
        let charts: XLSXChartReader.Context

        func readAnchor(_ node: XNode, into result: inout Result) {
            let anchor: ObjectAnchor?
            switch node.name {
            case "twoCellAnchor":
                anchor = twoCellAnchor(node)
            case "oneCellAnchor":
                anchor = oneCellAnchor(node)
            case "absoluteAnchor":
                anchor = absoluteAnchor(node)
            case "AlternateContent":
                // Anchors for newer features, with a fallback for older apps.
                if let choice = node.child("Choice") ?? node.child("Fallback") {
                    for child in choice.children { readAnchor(child, into: &result) }
                }
                return
            default:
                return
            }
            guard let anchor, let content = node.children.first(where: { Self.contentNames.contains($0.name) }) else {
                if node.children.contains(where: { Self.contentNames.contains($0.name) }) { result.warnings.insert(.images) }
                return
            }
            readContent(content, anchor: anchor, into: &result)
        }

        static let contentNames: Set<String> = ["pic", "graphicFrame", "sp", "grpSp", "cxnSp", "contentPart", "AlternateContent"]

        private func readContent(_ content: XNode, anchor: ObjectAnchor, into result: inout Result) {
            switch content.name {
            case "pic":
                readPicture(content, anchor: anchor, into: &result)
            case "graphicFrame":
                readFrame(content, anchor: anchor, into: &result)
            case "AlternateContent":
                // Excel 2016's chart types and slicers come with a stand-in shape as the fallback.
                guard let choice = content.child("Choice"), let inner = choice.children.first(where: { Self.contentNames.contains($0.name) })
                else {
                    result.warnings.insert(.images)
                    return
                }
                readContent(inner, anchor: anchor, into: &result)
            default:
                // Shapes, text boxes, connectors, groups and ink.
                result.warnings.insert(.images)
            }
        }

        private func readPicture(_ picture: XNode, anchor: ObjectAnchor, into result: inout Result) {
            let properties = picture.child("nvPicPr")?.child("cNvPr")
            guard let blip = picture.child("blipFill")?.child("blip"), let id = blip["embed"], let relationship = relationships[id],
                  !relationship.isExternal, let data = try? zip.read(relationship.target), let image = ImageData(data: data) else {
                // Linked pictures and formats PuggleSheets can't show (EMF, TIFF…).
                result.warnings.insert(.images)
                return
            }
            let name = properties?["name"] ?? ""
            let description = properties?["descr"] ?? ""
            if name.hasPrefix(XLSXDrawingWriter.cellImageMarker), result.cellImages[anchor.cell] == nil {
                result.cellImages[anchor.cell] = CellImage(image: image, altText: description)
            } else {
                result.objects.append(SheetObject(anchor: anchor, content: .image(image), title: properties?["title"] ?? "",
                                                  altDescription: description))
            }
            note(anchor, in: &result)
        }

        private func readFrame(_ frame: XNode, anchor: ObjectAnchor, into result: inout Result) {
            guard let graphic = frame.child("graphic")?.child("graphicData") else {
                result.warnings.insert(.images)
                return
            }
            let uri = graphic["uri"] ?? ""
            if uri == XLSXSlicers.drawingURI, let name = graphic.child("slicer")?["name"] {
                let properties = frame.child("nvGraphicFramePr")?.child("cNvPr")
                result.slicerFrames.append(SlicerFrame(position: result.objects.count, name: name, anchor: anchor,
                                                       title: properties?["title"] ?? "", description: properties?["descr"] ?? ""))
                note(anchor, in: &result)
                return
            }
            guard uri == XLSXDrawingReader.chartURI else {
                if uri.contains("chartex") {
                    result.warnings.insert(.charts)
                } else if uri.contains("slicer") {
                    result.warnings.insert(.filters)
                } else {
                    result.warnings.insert(.images)
                }
                return
            }
            guard let id = graphic.child("chart")?["id"], let relationship = relationships[id], !relationship.isExternal,
                  let data = try? zip.read(relationship.target) else {
                result.warnings.insert(.charts)
                return
            }
            let (spec, unsupported) = XLSXChartReader.read(data, context: charts)
            if unsupported { result.warnings.insert(.charts) }
            guard let spec else {
                result.warnings.insert(.charts)
                return
            }
            let properties = frame.child("nvGraphicFramePr")?.child("cNvPr")
            result.objects.append(SheetObject(anchor: anchor, content: .chart(spec), title: properties?["title"] ?? "",
                                              altDescription: properties?["descr"] ?? ""))
            note(anchor, in: &result)
        }

        private func note(_ anchor: ObjectAnchor, in result: inout Result) {
            result.lastRow = max(result.lastRow, anchor.cell.row)
            result.lastColumn = max(result.lastColumn, anchor.cell.column)
        }

        // MARK: - Anchors

        private struct Marker {
            var column: Int
            var columnOffset: Double
            var row: Int
            var rowOffset: Double
        }

        private func marker(_ node: XNode?) -> Marker? {
            guard let node, let column = XLSXValue.int(node.child("col")?.text), let row = XLSXValue.int(node.child("row")?.text),
                  column >= 0, row >= 0 else { return nil }
            return Marker(column: min(column, XLSXLimits.columns - 1),
                          columnOffset: XLSXEMU.pixels(max(0, XLSXValue.double(node.child("colOff")?.text) ?? 0)),
                          row: min(row, XLSXLimits.rows - 1),
                          rowOffset: XLSXEMU.pixels(max(0, XLSXValue.double(node.child("rowOff")?.text) ?? 0)))
        }

        /// A content element's own size (`a:ext` of its transform), in pixels.
        private func contentSize(_ anchor: XNode) -> (width: Double, height: Double)? {
            guard let content = anchor.children.first(where: { Self.contentNames.contains($0.name) }),
                  let extent = (content.child("spPr")?.child("xfrm") ?? content.child("xfrm") ?? content.child("grpSpPr")?.child("xfrm"))?
                .child("ext"),
                  let width = XLSXValue.double(extent["cx"]), let height = XLSXValue.double(extent["cy"]) else { return nil }
            return (XLSXEMU.pixels(width), XLSXEMU.pixels(height))
        }

        private func extent(_ node: XNode?) -> (width: Double, height: Double)? {
            guard let node, let width = XLSXValue.double(node["cx"]), let height = XLSXValue.double(node["cy"]) else { return nil }
            return (XLSXEMU.pixels(max(0, width)), XLSXEMU.pixels(max(0, height)))
        }

        private func twoCellAnchor(_ node: XNode) -> ObjectAnchor? {
            guard let from = marker(node.child("from")) else { return nil }
            var width = 0.0, height = 0.0
            if let to = marker(node.child("to")) {
                width = grid.width(fromColumn: from.column, fromOffset: from.columnOffset, toColumn: to.column, toOffset: to.columnOffset)
                height = grid.height(fromRow: from.row, fromOffset: from.rowOffset, toRow: to.row, toOffset: to.rowOffset)
            }
            // Over hidden columns or rows the cells give no size; the picture's own size does.
            if width <= 0 || height <= 0, let size = contentSize(node) {
                if width <= 0 { width = size.width }
                if height <= 0 { height = size.height }
            }
            return anchor(from, width: width, height: height)
        }

        private func oneCellAnchor(_ node: XNode) -> ObjectAnchor? {
            guard let from = marker(node.child("from")) else { return nil }
            let size = extent(node.child("ext")) ?? contentSize(node) ?? (0, 0)
            return anchor(from, width: size.width, height: size.height)
        }

        private func absoluteAnchor(_ node: XNode) -> ObjectAnchor? {
            guard let position = node.child("pos") else { return nil }
            let x = XLSXEMU.pixels(max(0, XLSXValue.double(position["x"]) ?? 0)), y = XLSXEMU.pixels(max(0, XLSXValue.double(position["y"]) ?? 0))
            let column = grid.column(from: 0, offset: x), row = grid.row(from: 0, offset: y)
            let size = extent(node.child("ext")) ?? contentSize(node) ?? (0, 0)
            return anchor(Marker(column: column.index, columnOffset: column.offset, row: row.index, rowOffset: row.offset),
                          width: size.width, height: size.height)
        }

        private func anchor(_ from: Marker, width: Double, height: Double) -> ObjectAnchor {
            func rounded(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }
            return ObjectAnchor(cell: CellAddress(row: from.row, column: from.column), offsetX: rounded(from.columnOffset),
                                offsetY: rounded(from.rowOffset), width: rounded(max(width, 1)), height: rounded(max(height, 1)))
        }
    }
}
