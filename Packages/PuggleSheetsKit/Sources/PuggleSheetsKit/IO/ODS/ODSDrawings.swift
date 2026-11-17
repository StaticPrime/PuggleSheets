import Foundation

/// Images and charts over the grid, and images in cells, as `draw:frame`s anchored to cells. Slicers have
/// no OpenDocument form: PuggleSheets' settings keep them.
///
/// LibreOffice writes a cell-anchored shape inside the `table:table-cell` holding its top-left corner:
/// `svg:x` and `svg:y` are its offsets into that cell, and `table:end-cell-address`, `table:end-x` and
/// `table:end-y` locate its bottom-right corner, counting hidden rows and columns at their full size.
/// Shapes in `table:shapes` are anchored to the page, at positions from the sheet's top-left corner.
enum ODSDrawings {
    /// `draw:name` of the frames that hold images in cells. Other frames stay over the grid.
    static let inCellImagePrefix = "PuggleSheets in-cell image"
    /// The automatic graphic style of written frames: no border, no fill behind transparent pictures.
    static let graphicStyleName = "gr1"
    static let graphicStyle = "<style:style style:name=\"\(graphicStyleName)\" style:family=\"graphic\">"
        + "<style:graphic-properties draw:stroke=\"none\" draw:fill=\"none\"/></style:style>"
}

/// Collects the frames a spreadsheet's sheets need, the pictures and chart objects they refer to, and the slicers.
struct ODSDrawingWriter {
    struct Picture {
        var path: String
        var data: Data
        var mediaType: String
    }

    struct ChartObject {
        /// "Object 1": the folder of the chart's parts.
        var path: String
        var content: Data
    }

    private(set) var pictures: [Picture] = []
    private var picturePaths: [ImageData: String] = [:]
    private(set) var charts: [ChartObject] = []
    /// Chart settings OpenDocument has no place for, kept in settings.xml.
    private(set) var chartExtras: [ODSChartExtras] = []
    /// Slicers by sheet index, which OpenDocument has no place for, kept in settings.xml.
    private(set) var slicers: [Int: [ODSSlicerExtras]] = [:]
    private(set) var hasFrames = false
    private var imageCount = 0

    var parts: [(path: String, data: Data, mediaType: String)] {
        var result = pictures.map { ($0.path, $0.data, $0.mediaType) }
        for chart in charts {
            result.append(("\(chart.path)/content.xml", chart.content, "text/xml"))
            result.append(("\(chart.path)/styles.xml", ODSChartWriter.stylesPart, "text/xml"))
            result.append(("\(chart.path)/meta.xml", ODSChartWriter.metaPart, "text/xml"))
        }
        return result
    }

    /// Manifest entries for the pictures and chart objects.
    func writeManifestEntries(into xml: inout XMLWriter) {
        for picture in pictures {
            xml.raw("<manifest:file-entry")
            xml.attribute("manifest:full-path", picture.path)
            xml.raw(" manifest:media-type=\"\(picture.mediaType)\"/>")
        }
        for chart in charts {
            for part in ["content.xml", "styles.xml", "meta.xml"] {
                xml.raw("<manifest:file-entry")
                xml.attribute("manifest:full-path", "\(chart.path)/\(part)")
                xml.raw(" manifest:media-type=\"text/xml\"/>")
            }
            xml.raw("<manifest:file-entry")
            xml.attribute("manifest:full-path", "\(chart.path)/")
            xml.raw(" manifest:version=\"1.3\" manifest:media-type=\"application/vnd.oasis.opendocument.chart\"/>")
        }
    }

    private mutating func picturePath(_ image: ImageData) -> String {
        if let path = picturePaths[image] { return path }
        let path = "Pictures/image\(pictures.count + 1).\(image.format.fileExtension)"
        picturePaths[image] = path
        pictures.append(Picture(path: path, data: image.data, mediaType: image.format.mimeType))
        return path
    }

    /// The frames of one sheet, by the cell each sits in: images in cells first (fitted inside their
    /// cell, keeping their shape), then the objects over the grid, back to front. Slicers go to `slicers`.
    mutating func frames(for sheet: Sheet, images cellImages: [(address: CellAddress, image: CellImage)], sheetIndex: Int, names: [String],
                         workbook: Workbook) -> [CellAddress: String] {
        guard !cellImages.isEmpty || !sheet.objects.isEmpty else { return [:] }
        var result: [CellAddress: String] = [:]
        defer { if !result.isEmpty { hasFrames = true } }
        let geometry = ODSSheetGeometry(sheet)
        let name = names[sheetIndex]
        var zIndex = 0
        func inside(_ cell: CellAddress) -> Bool {
            cell.row >= 0 && cell.column >= 0 && cell.row < ODSWriter.maximumRows && cell.column < ODSWriter.maximumColumns
        }

        for (address, image) in cellImages.sorted(by: { $0.address < $1.address }) where inside(address) {
            var area = CellRange(address)
            if let merge = sheet.merge(containing: address), merge.start == address { area = merge }
            let width = geometry.columns.start(of: area.end.column + 1) - geometry.columns.start(of: area.start.column)
            let height = geometry.rows.start(of: area.end.row + 1) - geometry.rows.start(of: area.start.row)
            let pixelWidth = Double(max(image.image.pixelWidth, 1)), pixelHeight = Double(max(image.image.pixelHeight, 1))
            let scale = max(0, min(width / pixelWidth, height / pixelHeight))
            let fitted = (width: pixelWidth * scale, height: pixelHeight * scale)
            let anchor = ObjectAnchor(cell: address, offsetX: (width - fitted.width) / 2, offsetY: (height - fitted.height) / 2,
                                      width: fitted.width, height: fitted.height)
            imageCount += 1
            let inner = imageElement(picturePath(image.image), image.image)
            result[address, default: ""] += frame(anchor, geometry: geometry, sheet: name, zIndex: zIndex,
                                                  name: "\(ODSDrawings.inCellImagePrefix) \(imageCount)", inner: inner,
                                                  title: "", description: image.altText)
            zIndex += 1
        }

        for (position, object) in sheet.objects.enumerated() {
            let inner: String
            var frameName: String?
            switch object.content {
            case .slicer(let spec):
                // OpenDocument (and LibreOffice) have no slicers: PuggleSheets' settings keep them, with their
                // place among the objects.
                slicers[sheetIndex, default: []].append(ODSSlicerExtras(index: position, id: object.id, anchor: object.anchor, spec: spec,
                                                                        title: object.title, description: object.altDescription))
                continue
            case .image(let image):
                guard inside(object.anchor.cell) else { continue }
                imageCount += 1
                frameName = "Image \(imageCount)"
                inner = imageElement(picturePath(image), image)
            case .chart(let spec):
                guard inside(object.anchor.cell) else { continue }
                let path = "Object \(charts.count + 1)"
                let layout = ODSChartLayout(spec: spec, sheetIndex: sheetIndex, workbook: workbook)
                let writer = ODSChartWriter(spec: spec, layout: layout, workbook: workbook, names: names,
                                            width: object.anchor.width, height: object.anchor.height)
                charts.append(ChartObject(path: path, content: writer.content()))
                chartExtras.append(ODSChartExtras(object: path, spec: spec, fingerprint: ODSChartExtras.fingerprint(layout: layout, kind: spec.kind)))
                var xml = XMLWriter(fragmentCapacity: 256)
                xml.raw("<draw:object")
                let ranges = writer.notifiedRanges
                if !ranges.isEmpty { xml.attribute("draw:notify-on-update-of-ranges", ranges) }
                xml.attribute("xlink:href", "./\(path)")
                xml.raw(" xlink:type=\"simple\" xlink:show=\"embed\" xlink:actuate=\"onLoad\"/>")
                inner = String(decoding: xml.bytes, as: UTF8.self)
            }
            result[object.anchor.cell, default: ""] += frame(object.anchor, geometry: geometry, sheet: name, zIndex: zIndex, name: frameName,
                                                             inner: inner, title: object.title, description: object.altDescription)
            zIndex += 1
        }
        return result
    }

    private func imageElement(_ path: String, _ image: ImageData) -> String {
        var xml = XMLWriter(fragmentCapacity: 160)
        xml.raw("<draw:image")
        xml.attribute("xlink:href", path)
        xml.raw(" xlink:type=\"simple\" xlink:show=\"embed\" xlink:actuate=\"onLoad\" draw:mime-type=\"\(image.format.mimeType)\"/>")
        return String(decoding: xml.bytes, as: UTF8.self)
    }

    private func frame(_ anchor: ObjectAnchor, geometry: ODSSheetGeometry, sheet: String, zIndex: Int, name: String?, inner: String,
                       title: String, description: String) -> String {
        var xml = XMLWriter(fragmentCapacity: 512)
        xml.raw("<draw:frame draw:z-index=\"\(zIndex)\"")
        if let name { xml.attribute("draw:name", name) }
        xml.raw(" draw:style-name=\"\(ODSDrawings.graphicStyleName)\"")
        xml.raw(" svg:width=\"\(ODSLength.drawing(pixels: anchor.width))\" svg:height=\"\(ODSLength.drawing(pixels: anchor.height))\"")
        xml.raw(" svg:x=\"\(ODSLength.drawing(pixels: anchor.offsetX))\" svg:y=\"\(ODSLength.drawing(pixels: anchor.offsetY))\"")
        let end = geometry.end(of: anchor)
        let endCell = CellAddress(row: min(end.cell.row, ODSWriter.maximumRows - 1), column: min(end.cell.column, ODSWriter.maximumColumns - 1))
        xml.attribute("table:end-cell-address", ODSFormula.address(sheet: sheet, range: CellRange(endCell)))
        xml.raw(" table:end-x=\"\(ODSLength.drawing(pixels: end.offsetX))\" table:end-y=\"\(ODSLength.drawing(pixels: end.offsetY))\">")
        xml.raw(inner)
        if !title.isEmpty {
            xml.raw("<svg:title>")
            xml.text(title)
            xml.raw("</svg:title>")
        }
        if !description.isEmpty {
            xml.raw("<svg:desc>")
            xml.text(description)
            xml.raw("</svg:desc>")
        }
        xml.raw("</draw:frame>")
        return String(decoding: xml.bytes, as: UTF8.self)
    }
}

/// Reads the frames of a sheet into objects over the grid and images in cells.
struct ODSDrawingReader {
    let zip: ZipReader
    /// The sheet names as the file writes them, by sheet index.
    let fileNames: [String]
    let chartExtras: [String: ODSChartExtras]

    /// Adds the frames of sheet `sheetIndex` to the workbook.
    func read(_ frames: [ODSParsedFrame], sheetIndex: Int, workbook: inout Workbook, warnings: inout Set<ImportWarning>) {
        guard !frames.isEmpty else { return }
        let fullGeometry = ODSSheetGeometry(workbook.sheets[sheetIndex])
        let pageGeometry = ODSSheetGeometry(workbook.sheets[sheetIndex], hiddenAsZero: true)
        var objects: [(z: Int, order: Int, object: SheetObject)] = []
        var cellImages: [(CellAddress, CellImage)] = []

        for frame in frames {
            let node = frame.node
            if node["transform"] != nil, node["x"] == nil { warnings.insert(.images) }
            let width = ODSLength.pixels(node["width"]) ?? 0
            let height = ODSLength.pixels(node["height"]) ?? 0
            let x = ODSLength.pixels(node["x"]) ?? 0, y = ODSLength.pixels(node["y"]) ?? 0
            var located: (cell: CellAddress, offsetX: Double, offsetY: Double)
            if let anchor = frame.anchor {
                let origin = fullGeometry.origin(of: anchor)
                located = fullGeometry.locate(x: origin.x + x, y: origin.y + y)
            } else {
                located = pageGeometry.locate(x: x, y: y)
            }
            // Shapes past the largest grid sit at its edge.
            located.cell = CellAddress(row: min(located.cell.row, ODSContentParser.maximumRows - 1),
                                       column: min(located.cell.column, ODSContentParser.maximumColumns - 1))
            var anchor = ObjectAnchor(cell: located.cell, offsetX: located.offsetX, offsetY: located.offsetY, width: width, height: height)
            if width <= 0 || height <= 0, frame.anchor != nil, let endText = node["end-cell-address"],
               let end = ODSFormula.parseAddress(Substring(endText))?.range?.start {
                // No size: the end cell gives it.
                let origin = fullGeometry.origin(of: located.cell)
                let endOrigin = fullGeometry.origin(of: end)
                anchor.width = max(0, endOrigin.x + (ODSLength.pixels(node["end-x"]) ?? 0) - origin.x - located.offsetX)
                anchor.height = max(0, endOrigin.y + (ODSLength.pixels(node["end-y"]) ?? 0) - origin.y - located.offsetY)
            }
            let title = Self.text(node.child("title"))
            let description = Self.text(node.child("desc"))
            let z = Int(node["z-index"] ?? "") ?? Int.max

            if let object = node.child("object") ?? node.child("object-ole") {
                guard object.name == "object", let content = chartContent(object["href"]) else {
                    warnings.insert(.charts)
                    continue
                }
                guard content.isChart else {
                    warnings.insert(.images)
                    continue
                }
                let path = Self.objectPath(object["href"] ?? "")
                guard let result = ODSChartReader.read(content.root, sheetIndex: sheetIndex, workbook: workbook, fileNames: fileNames,
                                                       extras: chartExtras[path]) else {
                    warnings.insert(.charts)
                    continue
                }
                warnings.formUnion(result.warnings)
                objects.append((z, frame.order, SheetObject(anchor: anchor, content: .chart(result.spec), title: title, altDescription: description)))
                continue
            }
            let images = node.children("image")
            guard !images.isEmpty else {
                // Text boxes, plug-ins and the like.
                warnings.insert(.images)
                continue
            }
            guard let image = images.lazy.compactMap({ self.image($0) }).first else {
                warnings.insert(.images)
                continue
            }
            if (node["name"] ?? "").hasPrefix(ODSDrawings.inCellImagePrefix) {
                cellImages.append((frame.anchor ?? located.cell, CellImage(image: image, altText: description.isEmpty ? title : description)))
                continue
            }
            objects.append((z, frame.order, SheetObject(anchor: anchor, content: .image(image), title: title, altDescription: description)))
        }

        var sheet = workbook.sheets[sheetIndex]
        for (address, image) in cellImages {
            var cell = sheet[address]
            cell.image = image
            sheet[address] = cell
            sheet.rowCount = max(sheet.rowCount, address.row + 1)
            sheet.columnCount = max(sheet.columnCount, address.column + 1)
        }
        sheet.objects += objects.sorted { ($0.z, $0.order) < ($1.z, $1.order) }.map(\.object)
        workbook.sheets[sheetIndex] = sheet
    }

    /// The text of `svg:title`, `svg:desc` or `text:p`, with its descendants' text.
    static func text(_ node: XNode?) -> String {
        guard let node else { return "" }
        var result = node.text
        for child in node.children {
            switch child.name {
            case "s": result += String(repeating: " ", count: max(1, min(Int(child["c"] ?? "1") ?? 1, 1000)))
            case "tab": result += "\t"
            case "line-break": result += "\n"
            default: result += text(child)
            }
        }
        return result
    }

    /// "./Object 1/" → "Object 1".
    static func objectPath(_ href: String) -> String {
        var path = href.trimmingCharacters(in: .whitespaces)
        if path.hasPrefix("./") { path.removeFirst(2) }
        while path.hasSuffix("/") { path.removeLast() }
        return path
    }

    private func chartContent(_ href: String?) -> (root: XNode, isChart: Bool)? {
        guard let href else { return nil }
        let path = Self.objectPath(href)
        guard !path.isEmpty, !path.contains("://"), let data = try? zip.read(path + "/content.xml"),
              let root = try? XMLTree.parse(data) else { return nil }
        let isChart = root.child("body")?.child("chart") != nil
        return (root, isChart)
    }

    private func image(_ node: XNode) -> ImageData? {
        if let binary = node.child("binary-data") {
            let text = binary.text.filter { !$0.isWhitespace }
            return Data(base64Encoded: text).flatMap(ImageData.init(data:))
        }
        guard var path = node["href"]?.trimmingCharacters(in: .whitespaces), !path.isEmpty, !path.contains("://") else { return nil }
        if path.hasPrefix("./") { path.removeFirst(2) }
        if path.contains("%"), let decoded = path.removingPercentEncoding { path = decoded }
        guard let data = try? zip.read(path) else { return nil }
        return ImageData(data: data)
    }
}
