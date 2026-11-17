import Foundation

/// Slicers on tables as Excel table slicers (Excel 2013 and later): a slicer cache per slicer
/// (xl/slicerCaches), each sheet's slicer list (xl/slicers), and a graphic frame in the drawing with a
/// stand-in shape for apps without slicers. The slicer's selection is the table's filter on its column.
/// Every slicer is also kept exactly in PuggleSheets' custom part; slicers on other ranges live only there.
enum XLSXSlicers {
    static let slicerType = "http://schemas.microsoft.com/office/2007/relationships/slicer"
    static let slicerCacheType = "http://schemas.microsoft.com/office/2007/relationships/slicerCache"
    static let slicerContentType = "application/vnd.ms-excel.slicer+xml"
    static let slicerCacheContentType = "application/vnd.ms-excel.slicerCache+xml"
    static let x14 = "http://schemas.microsoft.com/office/spreadsheetml/2009/9/main"
    static let x15 = "http://schemas.microsoft.com/office/spreadsheetml/2010/11/main"
    static let markupCompatibility = "http://schemas.openxmlformats.org/markup-compatibility/2006"
    static let drawingURI = "http://schemas.microsoft.com/office/drawing/2010/slicer"
    static let tableSlicerDrawing = "http://schemas.microsoft.com/office/drawing/2012/slicer"
    static let worksheetExtension = "{3A4CF648-6AED-40f4-86FF-DC5316D8AED3}"
    static let workbookExtension = "{46BE6895-7355-4a93-B00E-2C351335B9C9}"
    static let tableCacheExtension = "{2F2917AC-EB37-4324-AD4E-5DD8C200BD13}"

    // MARK: - Writing

    /// A slicer Excel can show: one whose range is exactly a table.
    struct Native {
        var objectID: UUID
        /// The sheet the slicer sits on.
        var sheet: Int
        var name: String
        var cacheName: String
        var caption: String
        /// The column's name in the table.
        var sourceName: String
        /// Excel's table id and the column's id in it (1-based, as tables number their columns).
        var tableID: Int
        var column: Int
        /// The table, and the sheet column filtered, for the table's filter.
        var table: UUID
        var sheetColumn: Int
        var criterion: FilterCriterion
    }

    /// The workbook's slicers Excel can show. `tableIDs` maps tables to their Excel ids, `columnNames`
    /// to their column names as written.
    static func plan(_ workbook: Workbook, tableIDs: [UUID: Int], columnNames: [UUID: [String]]) -> [Native] {
        var result: [Native] = []
        // Cache names are defined names, so they can't be a named range's or a table's name.
        var usedNames = Set<String>()
        var usedCaches = Set(workbook.namedRanges.map { $0.name.lowercased() } + workbook.sheets.flatMap { $0.tables.map { $0.name.lowercased() } })
        for (sheetIndex, sheet) in workbook.sheets.enumerated() {
            for object in sheet.objects {
                guard case .slicer(let spec) = object.content,
                      let resolved = workbook.resolve(spec.range, onSheet: sheetIndex),
                      let table = workbook.sheets[resolved.sheet].tables.first(where: { $0.range == resolved.range }),
                      let tableID = tableIDs[table.id], let names = columnNames[table.id],
                      spec.column >= 0, spec.column < names.count else { continue }
                let caption = spec.title.isEmpty ? names[spec.column] : spec.title
                var name = caption
                var number = 1
                while usedNames.contains(name.lowercased()) {
                    name = "\(caption) \(number)"
                    number += 1
                }
                usedNames.insert(name.lowercased())
                let base = "Slicer_" + String(names[spec.column].unicodeScalars.map { scalar -> Character in
                    CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII ? Character(scalar) : "_"
                })
                var cache = base
                number = 1
                while usedCaches.contains(cache.lowercased()) {
                    cache = base + String(number)
                    number += 1
                }
                usedCaches.insert(cache.lowercased())
                result.append(Native(objectID: object.id, sheet: sheetIndex, name: name, cacheName: cache, caption: caption,
                                     sourceName: names[spec.column], tableID: tableID, column: spec.column + 1, table: table.id,
                                     sheetColumn: table.range.start.column + spec.column, criterion: spec.criterion))
            }
        }
        return result
    }

    /// A slicer cache part.
    static func cachePart(_ slicer: Native) -> Data {
        var xml = XMLWriter()
        xml.raw("<slicerCacheDefinition xmlns=\"\(x14)\" xmlns:x=\"\(XLSXNamespace.main)\"")
        xml.attribute("name", slicer.cacheName)
        xml.attribute("sourceName", slicer.sourceName)
        xml.raw("><extLst><x:ext uri=\"\(tableCacheExtension)\" xmlns:x15=\"\(x15)\">")
        xml.raw("<x15:tableSlicerCache tableId=\"\(slicer.tableID)\" column=\"\(slicer.column)\"/></x:ext></extLst></slicerCacheDefinition>")
        return xml.data
    }

    /// A sheet's slicer part.
    static func slicerPart(_ slicers: [Native]) -> Data {
        var xml = XMLWriter()
        xml.raw("<slicers xmlns=\"\(x14)\" xmlns:x=\"\(XLSXNamespace.main)\">")
        for slicer in slicers {
            xml.raw("<slicer")
            xml.attribute("name", slicer.name)
            xml.attribute("cache", slicer.cacheName)
            xml.attribute("caption", slicer.caption)
            xml.raw(" rowHeight=\"241300\"/>")
        }
        xml.raw("</slicers>")
        return xml.data
    }

    /// The worksheet's extension listing its slicers.
    static func worksheetExtension(relationship: String) -> String {
        "<ext uri=\"\(worksheetExtension)\" xmlns:x15=\"\(x15)\"><x14:slicerList xmlns:x14=\"\(x14)\"><x14:slicer r:id=\"\(relationship)\"/>"
            + "</x14:slicerList></ext>"
    }

    /// The workbook's extension listing its slicer caches.
    static func workbookExtension(relationships: [String]) -> String {
        "<ext uri=\"\(workbookExtension)\" xmlns:x15=\"\(x15)\"><x15:slicerCaches xmlns:x14=\"\(x14)\">"
            + relationships.map { "<x14:slicerCache r:id=\"\($0)\"/>" }.joined() + "</x15:slicerCaches></ext>"
    }

    /// The drawing's frame for a slicer, with a plain shape for apps that can't show slicers.
    static func writeFrame(id: Int, name: String, title: String, description: String, frame: XLSXDrawingWriter.Frame,
                           into xml: inout XMLWriter) {
        xml.raw("<mc:AlternateContent xmlns:mc=\"\(markupCompatibility)\"><mc:Choice xmlns:sle15=\"\(tableSlicerDrawing)\" Requires=\"sle15\">")
        xml.raw("<xdr:graphicFrame macro=\"\"><xdr:nvGraphicFramePr><xdr:cNvPr id=\"\(id)\"")
        xml.attribute("name", name)
        if !description.isEmpty { xml.attribute("descr", description) }
        if !title.isEmpty { xml.attribute("title", title) }
        xml.raw("/><xdr:cNvGraphicFramePr/></xdr:nvGraphicFramePr>")
        xml.raw("<xdr:xfrm><a:off x=\"\(frame.x)\" y=\"\(frame.y)\"/><a:ext cx=\"\(frame.width)\" cy=\"\(frame.height)\"/></xdr:xfrm>")
        xml.raw("<a:graphic><a:graphicData uri=\"\(drawingURI)\"><sle:slicer xmlns:sle=\"\(drawingURI)\"")
        xml.attribute("name", name)
        xml.raw("/></a:graphicData></a:graphic></xdr:graphicFrame></mc:Choice><mc:Fallback>")
        xml.raw("<xdr:sp macro=\"\" textlink=\"\"><xdr:nvSpPr><xdr:cNvPr id=\"0\" name=\"\"/><xdr:cNvSpPr><a:spLocks noTextEdit=\"1\"/>"
            + "</xdr:cNvSpPr></xdr:nvSpPr><xdr:spPr><a:xfrm><a:off x=\"\(frame.x)\" y=\"\(frame.y)\"/><a:ext cx=\"\(frame.width)\" "
            + "cy=\"\(frame.height)\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom><a:solidFill><a:prstClr val=\"white\"/>"
            + "</a:solidFill><a:ln w=\"1\"><a:solidFill><a:prstClr val=\"green\"/></a:solidFill></a:ln></xdr:spPr>"
            + "<xdr:txBody><a:bodyPr vertOverflow=\"clip\" horzOverflow=\"clip\"/><a:lstStyle/><a:p><a:r><a:rPr lang=\"en-US\" sz=\"1100\"/>"
            + "<a:t>This shape represents a table slicer. Table slicers are supported in Excel 2013 and later. If the shape was "
            + "modified in an earlier version of Excel, or if the workbook was saved in Excel 2007 or earlier, the slicer can't be used."
            + "</a:t></a:r></a:p></xdr:txBody></xdr:sp></mc:Fallback></mc:AlternateContent>")
    }

    // MARK: - Reading

    /// What a slicer cache filters: a table column, or (nil) something PuggleSheets can't keep, such as
    /// a pivot table.
    static func cache(_ data: Data) -> (name: String, table: (id: Int, column: Int)?)? {
        guard let root = try? XMLTree.parse(data), root.name == "slicerCacheDefinition", let name = root["name"] else { return nil }
        if let table = root.firstDescendant("tableSlicerCache"), let id = XLSXValue.int(table["tableId"]),
           let column = XLSXValue.int(table["column"]) {
            return (name, (id, column))
        }
        return (name, nil)
    }

    /// A sheet's slicers: name → its cache and caption.
    static func slicers(_ data: Data) -> [String: (cache: String, caption: String)] {
        guard let root = try? XMLTree.parse(data), root.name == "slicers" else { return [:] }
        var result: [String: (cache: String, caption: String)] = [:]
        for slicer in root.children("slicer") {
            if let name = slicer["name"], let cache = slicer["cache"] { result[name] = (cache, slicer["caption"] ?? name) }
        }
        return result
    }
}
