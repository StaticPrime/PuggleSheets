import Foundation

/// Writes a sheet's drawing (xl/drawings/drawingN.xml): its floating images and charts, anchored to
/// cells, and its in-cell images as pictures fitted to their cells.
enum XLSXDrawingWriter {
    /// Pictures standing for in-cell images carry this name, so PuggleSheets puts them back in their
    /// cell; other apps show them as pictures over the cell.
    static let cellImageMarker = "PuggleSheets cell image"

    struct Context {
        let workbook: Workbook
        let sheetIndex: Int
        let sheetNames: [String]
        /// Slicers Excel can show (on tables), by object id; other slicers aren't drawn.
        var nativeSlicers: [UUID: XLSXSlicers.Native] = [:]
    }

    /// Media already written, so an image used more than once is stored once.
    struct Media {
        var paths: [ImageData: String] = [:]
    }

    /// Writes the sheet's drawing with its charts and images into `parts`. Returns the drawing's target
    /// relative to the worksheet, or nil when the sheet has nothing to draw.
    static func write(_ sheet: Sheet, cellImages addresses: [CellAddress], context: Context, counters: inout XLSXPartCounters,
                      media: inout Media, parts: inout XLSXExtraParts) -> String? {
        let cellImages = addresses.compactMap { address -> (address: CellAddress, image: CellImage)? in
            guard let image = sheet.cells[address]?.image, address.row < XLSXLimits.rows, address.column < XLSXLimits.columns,
                  address.row >= 0, address.column >= 0 else { return nil }
            return (address, image)
        }.sorted { $0.address < $1.address }
        let objects = sheet.objects.filter { object in
            if case .slicer = object.content { return context.nativeSlicers[object.id] != nil }
            return true
        }
        guard !objects.isEmpty || !cellImages.isEmpty else { return nil }

        counters.drawings += 1
        let number = counters.drawings
        let grid = XLSXSheetGrid(sheet: sheet)
        var relationships = XLSXRelationshipsWriter()
        var xml = XMLWriter(reservingCapacity: 1024 + (objects.count + cellImages.count) * 1024)
        xml.raw("<xdr:wsDr xmlns:xdr=\"\(XLSXNamespace.spreadsheetDrawing)\" xmlns:a=\"\(XLSXNamespace.drawingMain)\" "
            + "xmlns:r=\"\(XLSXNamespace.relationships)\" xmlns:c=\"\(XLSXNamespace.chart)\">")
        var shapeID = 1
        for object in objects {
            shapeID += 1
            switch object.content {
            case .slicer:
                guard let slicer = context.nativeSlicers[object.id] else { continue }
                writeAnchor(object.anchor, grid: grid, editAs: "oneCell", into: &xml) { xml, frame in
                    XLSXSlicers.writeFrame(id: shapeID, name: slicer.name, title: object.title, description: object.altDescription,
                                           frame: frame, into: &xml)
                }
            case .image(let image):
                let target = mediaTarget(image, counters: &counters, media: &media, parts: &parts)
                let id = relationships.add(type: XLSXRelationshipType.image, target: target)
                writeAnchor(object.anchor, grid: grid, editAs: "oneCell", into: &xml) { xml, frame in
                    writePicture(id: shapeID, name: "Picture \(shapeID - 1)", title: object.title, description: object.altDescription,
                                 relationship: id, frame: frame, into: &xml)
                }
            case .chart(let spec):
                counters.charts += 1
                let chart = counters.charts
                let chartContext = XLSXChartWriter.Context(workbook: context.workbook, sheetIndex: context.sheetIndex,
                                                           sheetNames: context.sheetNames)
                parts.add("xl/charts/chart\(chart).xml", XLSXChartWriter.chartPart(spec, context: chartContext),
                          contentType: XLSXContentType.chart)
                let id = relationships.add(type: XLSXRelationshipType.chart, target: "../charts/chart\(chart).xml")
                writeAnchor(object.anchor, grid: grid, editAs: "oneCell", into: &xml) { xml, frame in
                    writeChartFrame(id: shapeID, name: "Chart \(shapeID - 1)", title: object.title, description: object.altDescription,
                                    relationship: id, frame: frame, into: &xml)
                }
            }
        }
        for (address, image) in cellImages {
            shapeID += 1
            let target = mediaTarget(image.image, counters: &counters, media: &media, parts: &parts)
            let id = relationships.add(type: XLSXRelationshipType.image, target: target)
            // In-cell images move and size with their cell.
            writeAnchor(fittedAnchor(image.image, in: address, sheet: sheet, grid: grid), grid: grid, editAs: "twoCell", into: &xml) { xml, frame in
                writePicture(id: shapeID, name: "\(cellImageMarker) \(address.a1)", title: "", description: image.altText,
                             relationship: id, frame: frame, into: &xml)
            }
        }
        xml.raw("</xdr:wsDr>")
        parts.add("xl/drawings/drawing\(number).xml", xml.data, contentType: XLSXContentType.drawing)
        parts.add("xl/drawings/_rels/drawing\(number).xml.rels", relationships.data())
        return "../drawings/drawing\(number).xml"
    }

    /// The image's place in its cell (or the merged block the cell starts): as large as fits without
    /// distorting it, centered.
    static func fittedAnchor(_ image: ImageData, in address: CellAddress, sheet: Sheet, grid: XLSXSheetGrid) -> ObjectAnchor {
        let block = sheet.merge(containing: address).flatMap { $0.start == address ? $0 : nil } ?? CellRange(address)
        let width = block.columns.reduce(0.0) { $0 + grid.columnWidth($1) }
        let height = block.rows.reduce(0.0) { $0 + grid.rowHeight($1) }
        let imageWidth = Double(max(image.pixelWidth, 1)), imageHeight = Double(max(image.pixelHeight, 1))
        guard width > 0, height > 0 else { return ObjectAnchor(cell: address, width: 1, height: 1) }
        let scale = min(width / imageWidth, height / imageHeight)
        let fittedWidth = max(1, (imageWidth * scale).rounded(.down)), fittedHeight = max(1, (imageHeight * scale).rounded(.down))
        return ObjectAnchor(cell: address, offsetX: ((width - fittedWidth) / 2).rounded(.down), offsetY: ((height - fittedHeight) / 2).rounded(.down),
                            width: fittedWidth, height: fittedHeight)
    }

    /// The object's position and size in EMU from the sheet's top-left corner.
    struct Frame {
        var x: Int
        var y: Int
        var width: Int
        var height: Int
    }

    /// A two-cell anchor: the cells and offsets of the top-left and bottom-right corners.
    static func writeAnchor(_ anchor: ObjectAnchor, grid: XLSXSheetGrid, editAs: String, into xml: inout XMLWriter,
                            content: (inout XMLWriter, Frame) -> Void) {
        let column = min(max(anchor.cell.column, 0), XLSXLimits.columns - 1)
        let row = min(max(anchor.cell.row, 0), XLSXLimits.rows - 1)
        let width = max(0, anchor.width), height = max(0, anchor.height)
        let from = (column: grid.column(from: column, offset: anchor.offsetX), row: grid.row(from: row, offset: anchor.offsetY))
        let to = (column: grid.column(from: column, offset: anchor.offsetX + width), row: grid.row(from: row, offset: anchor.offsetY + height))
        xml.raw("<xdr:twoCellAnchor editAs=\"\(editAs)\">")
        func marker(_ name: String, column: (index: Int, offset: Double), row: (index: Int, offset: Double)) {
            xml.raw("<xdr:\(name)><xdr:col>\(column.index)</xdr:col><xdr:colOff>\(XLSXEMU.from(pixels: column.offset))</xdr:colOff>"
                + "<xdr:row>\(row.index)</xdr:row><xdr:rowOff>\(XLSXEMU.from(pixels: row.offset))</xdr:rowOff></xdr:\(name)>")
        }
        marker("from", column: from.column, row: from.row)
        marker("to", column: to.column, row: to.row)
        let frame = Frame(x: XLSXEMU.from(pixels: grid.x(ofColumn: from.column.index) + from.column.offset),
                          y: XLSXEMU.from(pixels: grid.y(ofRow: from.row.index) + from.row.offset),
                          width: XLSXEMU.from(pixels: width), height: XLSXEMU.from(pixels: height))
        content(&xml, frame)
        xml.raw("<xdr:clientData/></xdr:twoCellAnchor>")
    }

    private static func writeNonVisualProperties(id: Int, name: String, title: String, description: String, into xml: inout XMLWriter) {
        xml.raw("<xdr:cNvPr id=\"\(id)\"")
        xml.attribute("name", name)
        if !description.isEmpty { xml.attribute("descr", description) }
        if !title.isEmpty { xml.attribute("title", title) }
        xml.raw("/>")
    }

    private static func writePicture(id: Int, name: String, title: String, description: String, relationship: String, frame: Frame,
                                     into xml: inout XMLWriter) {
        xml.raw("<xdr:pic><xdr:nvPicPr>")
        writeNonVisualProperties(id: id, name: name, title: title, description: description, into: &xml)
        xml.raw("<xdr:cNvPicPr><a:picLocks noChangeAspect=\"1\"/></xdr:cNvPicPr></xdr:nvPicPr>")
        xml.raw("<xdr:blipFill><a:blip r:embed=\"\(relationship)\"/><a:stretch><a:fillRect/></a:stretch></xdr:blipFill>")
        xml.raw("<xdr:spPr><a:xfrm><a:off x=\"\(frame.x)\" y=\"\(frame.y)\"/><a:ext cx=\"\(frame.width)\" cy=\"\(frame.height)\"/></a:xfrm>"
            + "<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></xdr:spPr></xdr:pic>")
    }

    private static func writeChartFrame(id: Int, name: String, title: String, description: String, relationship: String, frame: Frame,
                                        into xml: inout XMLWriter) {
        xml.raw("<xdr:graphicFrame macro=\"\"><xdr:nvGraphicFramePr>")
        writeNonVisualProperties(id: id, name: name, title: title, description: description, into: &xml)
        xml.raw("<xdr:cNvGraphicFramePr/></xdr:nvGraphicFramePr>")
        xml.raw("<xdr:xfrm><a:off x=\"\(frame.x)\" y=\"\(frame.y)\"/><a:ext cx=\"\(frame.width)\" cy=\"\(frame.height)\"/></xdr:xfrm>")
        xml.raw("<a:graphic><a:graphicData uri=\"\(XLSXNamespace.chart)\"><c:chart r:id=\"\(relationship)\"/></a:graphicData></a:graphic>")
        xml.raw("</xdr:graphicFrame>")
    }

    /// The media part for an image (written once), as a target relative to the drawing.
    private static func mediaTarget(_ image: ImageData, counters: inout XLSXPartCounters, media: inout Media,
                                    parts: inout XLSXExtraParts) -> String {
        if let path = media.paths[image] { return "../media/" + path }
        counters.images += 1
        let name = "image\(counters.images).\(image.format.fileExtension)"
        parts.add("xl/media/" + name, image.data)
        parts.addDefault(extension: image.format.fileExtension, contentType: image.format.mimeType)
        media.paths[image] = name
        return "../media/" + name
    }
}
