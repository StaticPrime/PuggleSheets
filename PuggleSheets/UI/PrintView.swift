import AppKit
import PuggleSheetsKit
import SwiftUI

/// Draws printed pages, stacked top to bottom, for the print system, PDFs and the preview.
final class PrintPagesView: NSView {
    private unowned let controller: SpreadsheetController
    let settings: PrintSettings
    let pages: [PrintPage]
    private let title: String
    private let date = Date()
    private var renderers: [Int: GridView] = [:]

    init(controller: SpreadsheetController, settings: PrintSettings, title: String) {
        self.controller = controller
        self.settings = settings
        self.title = title
        let selection = controller.selection.current
        pages = PrintLayout.pages(for: settings, workbook: controller.workbook, activeSheet: controller.activeSheetIndex, selection: selection)
        let paper = settings.paperSize
        super.init(frame: NSRect(x: 0, y: 0, width: paper.width, height: paper.height * CGFloat(max(1, pages.count))))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        range.pointee = NSRange(location: 1, length: max(1, pages.count))
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect {
        let paper = settings.paperSize
        return NSRect(x: 0, y: CGFloat(page - 1) * paper.height, width: paper.width, height: paper.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let height = settings.paperSize.height
        let first = max(0, Int(dirtyRect.minY / height)), last = min(pages.count - 1, Int((dirtyRect.maxY - 1) / height))
        guard first <= last else { return }
        for index in first...last { drawPage(index, in: rectForPage(index + 1)) }
    }

    /// One page: white paper, the cells placed by the alignment settings, then headers and footers.
    func drawPage(_ index: Int, in pageRect: NSRect) {
        NSColor.white.setFill()
        pageRect.fill()
        guard pages.indices.contains(index) else { return }
        let page = pages[index]
        let content = settings.contentRect.offsetBy(dx: pageRect.minX, dy: pageRect.minY)
        let size = CGSize(width: page.size.width * page.scale, height: page.size.height * page.scale)
        var origin = content.origin
        switch settings.alignment {
        case .start: break
        case .center: origin.x += max(0, (content.width - size.width) / 2)
        case .end: origin.x += max(0, content.width - size.width)
        }
        switch settings.verticalAlignment {
        case .top: break
        case .middle: origin.y += max(0, (content.height - size.height) / 2)
        case .bottom: origin.y += max(0, content.height - size.height)
        }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: content).addClip()
        let transform = NSAffineTransform()
        transform.translateX(by: origin.x, yBy: origin.y)
        transform.scale(by: page.scale)
        transform.concat()
        renderer(for: page.sheetIndex).drawPrintPage(rows: page.rows, columns: page.columns)
        NSGraphicsContext.restoreGraphicsState()
        drawHeadersAndFooters(page: page, number: index + 1, in: pageRect)
    }

    private func renderer(for sheetIndex: Int) -> GridView {
        if let renderer = renderers[sheetIndex] { return renderer }
        let renderer = GridView(controller: controller)
        renderer.printSettings = (sheetIndex, settings.gridlines)
        renderer.frame = NSRect(x: 0, y: 0, width: 100_000, height: 100_000)
        renderer.reloadLayout()
        renderers[sheetIndex] = renderer
        return renderer
    }

    private func drawHeadersAndFooters(page: PrintPage, number: Int, in pageRect: NSRect) {
        guard settings.hasHeadersOrFooters else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont(name: "Arial", size: 8) ?? NSFont.systemFont(ofSize: 8),
                                                         .foregroundColor: NSColor.black]
        let insets = settings.margins.insets
        let headerY = pageRect.minY + max(6, insets.top / 2 - 5)
        let footerY = pageRect.maxY - max(14, insets.bottom / 2 + 5)
        let left = pageRect.minX + insets.left, right = pageRect.maxX - insets.right
        func draw(_ text: String, x: CGFloat, y: CGFloat, trailing: Bool) {
            let width = (text as NSString).size(withAttributes: attributes).width
            (text as NSString).draw(at: CGPoint(x: trailing ? x - width : x, y: y), withAttributes: attributes)
        }
        if settings.workbookTitle { draw(title, x: left, y: headerY, trailing: false) }
        if settings.sheetName { draw(controller.workbook.sheets[page.sheetIndex].name, x: right, y: headerY, trailing: true) }
        var stamp: [String] = []
        if settings.currentDate { stamp.append(date.formatted(date: .numeric, time: .omitted)) }
        if settings.currentTime { stamp.append(date.formatted(date: .omitted, time: .shortened)) }
        if !stamp.isEmpty { draw(stamp.joined(separator: " "), x: left, y: footerY, trailing: false) }
        if settings.pageNumbers { draw("\(number)", x: right, y: footerY, trailing: true) }
    }

    /// A picture of one page, for the preview.
    func image(forPage index: Int) -> NSImage {
        let size = settings.paperSize
        return NSImage(size: size, flipped: true) { [self] bounds in
            drawPage(index, in: bounds)
            return true
        }
    }

    /// The pages as a PDF document.
    func pdfData() -> Data {
        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: settings.paperSize)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return Data() }
        for index in pages.indices {
            context.beginPDFPage(nil)
            context.translateBy(x: 0, y: mediaBox.height)
            context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            drawPage(index, in: CGRect(origin: .zero, size: mediaBox.size))
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    /// Print info that leaves layout to this view: no margins of its own, and the paper chosen.
    func printInfo() -> NSPrintInfo {
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.paperSize = settings.paper.size
        info.orientation = settings.landscape ? .landscape : .portrait
        info.topMargin = 0
        info.bottomMargin = 0
        info.leftMargin = 0
        info.rightMargin = 0
        info.horizontalPagination = .clip
        info.verticalPagination = .clip
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        return info
    }
}

/// The print settings: a preview of the pages and the settings beside it.
struct PrintSettingsView: View {
    @State var settings: PrintSettings
    let makeView: (PrintSettings) -> PrintPagesView
    let actionTitle: String
    let finish: (PrintSettings?) -> Void
    @State private var pagesView: PrintPagesView?
    @State private var revision = 0

    var body: some View {
        HStack(spacing: 0) {
            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(red: 0xE8 / 255, green: 0xEA / 255, blue: 0xED / 255))
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Print settings").font(.system(size: 18))
                    Spacer()
                    if let pagesView {
                        Text(pagesView.pages.count == 1 ? "1 page" : "\(pagesView.pages.count) pages")
                            .font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                    }
                }
                .padding(.bottom, 14)
                ScrollView {
                    controls.frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Spacer()
                    PanelButton(title: "Cancel", primary: false) { finish(nil) }
                        .keyboardShortcut(.cancelAction)
                    PanelButton(title: actionTitle, isEnabled: !(pagesView?.pages.isEmpty ?? true)) { finish(settings) }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 12)
            }
            .padding(20)
            .frame(width: 320)
        }
        .frame(width: 1000, height: 700)
        .onAppear { pagesView = makeView(settings) }
        .onChange(of: settings) { _, new in
            pagesView = makeView(new)
            revision += 1
        }
    }

    @ViewBuilder private var preview: some View {
        if let pagesView, !pagesView.pages.isEmpty {
            GeometryReader { geometry in
                let paper = settings.paperSize
                let width = min(paper.width * 1.1, geometry.size.width - 80)
                ScrollView {
                    LazyVStack(spacing: 18) {
                        ForEach(0..<pagesView.pages.count, id: \.self) { index in
                            Image(nsImage: pagesView.image(forPage: index))
                                .resizable()
                                .frame(width: width, height: width * paper.height / paper.width)
                                .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                        }
                    }
                    .padding(30)
                    .frame(maxWidth: .infinity)
                    .id(revision)
                }
            }
        } else {
            Text("There’s nothing to print.").font(.system(size: 14)).foregroundStyle(Theme.secondaryText)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelSection(title: "Print") {
                Picker("", selection: $settings.scope) { ForEach(PrintSettings.Scope.allCases) { Text($0.rawValue).tag($0) } }
                    .labelsHidden()
            }
            PanelSection(title: "Paper size") {
                Picker("", selection: $settings.paper) { ForEach(PrintSettings.Paper.allCases) { Text($0.rawValue).tag($0) } }
                    .labelsHidden()
            }
            PanelSection(title: "Page orientation") {
                Picker("", selection: $settings.landscape) {
                    Text("Landscape").tag(true)
                    Text("Portrait").tag(false)
                }
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()
                .labelsHidden()
            }
            PanelSection(title: "Scale") {
                Picker("", selection: $settings.scale) { ForEach(PrintSettings.Scale.allCases) { Text($0.rawValue).tag($0) } }
                    .labelsHidden()
                if settings.scale == .custom {
                    HStack {
                        TextField("", value: $settings.customScale, format: .number).frame(width: 60)
                        Text("%").font(.system(size: 13))
                    }
                }
            }
            PanelSection(title: "Margins") {
                Picker("", selection: $settings.margins) { ForEach(PrintSettings.Margins.allCases) { Text($0.rawValue).tag($0) } }
                    .labelsHidden()
            }
            PanelSection(title: "Formatting") {
                Toggle("Show gridlines", isOn: $settings.gridlines)
                Text("Page order").font(.system(size: 12)).foregroundStyle(Theme.secondaryText).padding(.top, 4)
                Picker("", selection: $settings.downThenOver) {
                    Text("Over, then down").tag(false)
                    Text("Down, then over").tag(true)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                Text("Alignment").font(.system(size: 12)).foregroundStyle(Theme.secondaryText).padding(.top, 4)
                HStack {
                    Picker("Horizontal", selection: $settings.alignment) { ForEach(PrintSettings.Alignment.allCases) { Text($0.rawValue).tag($0) } }
                    Picker("Vertical", selection: $settings.verticalAlignment) { ForEach(PrintSettings.VerticalAlignment.allCases) { Text($0.rawValue).tag($0) } }
                }
                .font(.system(size: 12))
            }
            PanelSection(title: "Headers & footers") {
                Toggle("Page numbers", isOn: $settings.pageNumbers)
                Toggle("Workbook title", isOn: $settings.workbookTitle)
                Toggle("Sheet name", isOn: $settings.sheetName)
                Toggle("Current date", isOn: $settings.currentDate)
                Toggle("Current time", isOn: $settings.currentTime)
            }
        }
        .toggleStyle(.checkbox)
        .font(.system(size: 13))
    }
}
