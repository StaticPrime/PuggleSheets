import AppKit
import CloudKit
import PuggleSheetsKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MenuBuilder.makeMainMenu()
        UserDefaults.standard.register(defaults: ["NSFullScreenMenuItemEverywhere": false])
        CollaborationController.shared = CollaborationController(service: makeCollaborationService())
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        CollaborationController.shared.start()
        #if DEBUG
        DebugLaunchOptions.runIfRequested()
        SelfTest.runIfRequested()
        #endif
    }

    /// iCloud, where spreadsheets are shared; in debug runs that ask for it, a stand-in for it.
    private func makeCollaborationService() -> CollaborationService {
        #if DEBUG
        if StandInCloud.isRequested { return StandInCollaboration(me: StandInCloud.me, cloud: .shared) }
        #endif
        if CloudKitCollaboration.isEntitled { return CloudKitCollaboration() }
        return UnavailableCollaboration(reason: "Sharing goes through iCloud, which this copy of PuggleSheets isn’t signed to use.")
    }

    // MARK: Shared spreadsheets

    /// Joins a spreadsheet someone shared, from the link they sent, and opens it.
    func application(_ application: NSApplication, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        CollaborationController.shared.accept(metadata)
    }

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        CollaborationController.shared.receivedPush(userInfo)
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { true }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    @objc func showAboutWindow(_ sender: Any?) { AboutWindowController.show() }
}

#if DEBUG
/// Launch arguments used during development to check rendering without manual interaction:
/// `-PSSampleDocument YES` fills new spreadsheets with sample content, and
/// `-PSSnapshot <file name>` writes a PNG of the first window to the app's temporary folder and quits.
enum DebugLaunchOptions {
    static var wantsSample: Bool { UserDefaults.standard.bool(forKey: "PSSampleDocument") }

    /// `-PSBenchmark YES`: fills a sheet with 100,000 cells and times recalculation and redrawing.
    static func runBenchmark() {
        guard UserDefaults.standard.bool(forKey: "PSBenchmark") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard let window = NSApp.windows.compactMap({ $0.windowController as? DocumentWindowController }).first,
                  let document = window.spreadsheet else { return }
            var sheet = Sheet(name: "Benchmark", rowCount: 5000, columnCount: 26)
            var cells: [CellAddress: Cell] = [:]
            for row in 0..<4000 {
                for column in 0..<25 {
                    let address = CellAddress(row: row, column: column)
                    switch column % 5 {
                    case 0: cells[address] = Cell(value: .number(Double(row * 25 + column)))
                    case 1: cells[address] = Cell(value: .text("Item \(row)"))
                    case 2: cells[address] = Cell(formula: "=A\(row + 1)*2")
                    case 3: cells[address] = Cell(value: .number(Double(row) / 7), format: { var f = CellFormat(); f.numberFormat = "#,##0.00"; return f }())
                    default: cells[address] = Cell(formula: "=SUM(A\(row + 1):D\(row + 1))")
                    }
                }
            }
            sheet.setCells(cells)
            document.workbook = Workbook(sheets: [sheet])
            let start = Date()
            window.controller.reloadFromDocument()
            print(String(format: "BENCHMARK: load and recalculate %d cells: %.0f ms", cells.count, Date().timeIntervalSince(start) * 1000))
            let grid = window.grid
            let drawStart = Date()
            for step in 0..<30 {
                grid.setScrollOffset(CGPoint(x: CGFloat(step * 37), y: CGFloat(step * 911)))
                grid.display()
            }
            print(String(format: "BENCHMARK: draw: %.1f ms per frame", Date().timeIntervalSince(drawStart) * 1000 / 30))
            let editStart = Date()
            window.controller.commitInput("5", at: CellAddress(row: 10, column: 0))
            print(String(format: "BENCHMARK: edit and recalculate: %.1f ms", Date().timeIntervalSince(editStart) * 1000))
            fflush(stdout)
            exit(0)
        }
    }

    static func runIfRequested() {
        runBenchmark()
        guard let name = UserDefaults.standard.string(forKey: "PSSnapshot") else { return }
        let defaults = UserDefaults.standard
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard let controller = NSApp.windows.compactMap({ $0.windowController as? DocumentWindowController }).first else { return }
            let width = defaults.double(forKey: "PSWindowWidth")
            if width > 0, let window = controller.window {
                window.setContentSize(NSSize(width: width, height: window.contentLayoutRect.height))
            }
            let zoom = defaults.double(forKey: "PSZoom")
            if zoom > 0 { controller.setZoom(zoom) }
            if let sheet = defaults.string(forKey: "PSSheet"), let index = controller.controller.workbook.sheetIndex(named: sheet) {
                controller.controller.showSheet(id: controller.controller.workbook.sheets[index].id)
            }
            if let reference = defaults.string(forKey: "PSSelect"), let range = CellRange(a1: reference) {
                controller.controller.selection = GridSelection(range: range)
            }
            if let text = defaults.string(forKey: "PSType") {
                controller.grid.beginEditing(replacingWith: text, entry: .replace)
            }
            if let name = defaults.string(forKey: "PSWriteFile"),
               let format = SpreadsheetFileFormat(typeName: (name as NSString).pathExtension) {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
                let data = try? SpreadsheetIO.write(controller.controller.workbook, activeSheet: controller.controller.activeSheetIndex, format: format)
                print("PSWriteFile: \((try? data?.write(to: url)) != nil ? "wrote" : "failed") \(url.path)")
            }
            if let query = defaults.string(forKey: "PSFind") {
                controller.find.show()
                controller.find.state.query = query
                controller.find.search()
            }
            if let query = defaults.string(forKey: "PSFindReplace") {
                controller.findReplace.state.options.query = query
                controller.findReplace.state.options.replacement = defaults.string(forKey: "PSReplaceWith") ?? ""
                controller.showFindReplace()
                if defaults.bool(forKey: "PSReplaceAll") { controller.findReplace.replaceAll() } else { controller.findReplace.find() }
            }
            if let name = defaults.string(forKey: "PSWritePDF") {
                var settings = PrintSettings()
                settings.pageNumbers = true
                settings.sheetName = true
                let view = PrintPagesView(controller: controller.controller, settings: settings, title: controller.state.title)
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
                print("PSWritePDF: \(view.pages.count) pages, \((try? view.pdfData().write(to: url)) != nil ? "wrote" : "failed") \(url.path)")
            }
            if defaults.bool(forKey: "PSPrintSettings") { controller.showPrintSettings(export: false) }
            let sheet = controller.controller.sheet
            if defaults.bool(forKey: "PSSelectObject"), let object = sheet.objects.first { controller.controller.selectedObjectID = object.id }
            if defaults.bool(forKey: "PSChartEditor"), let chart = sheet.objects.first(where: { $0.chart != nil }) { controller.showChartEditor(chart.id) }
            if defaults.bool(forKey: "PSPivotEditor"), let pivot = sheet.pivotTables.first { controller.showPivotEditor(pivot.id) }
            if defaults.bool(forKey: "PSFilterView"), let view = sheet.filterViews.first { controller.controller.openFilterView(view.id) }
            if defaults.bool(forKey: "PSLinkEditor") { controller.showLinkEditor() }
            if defaults.bool(forKey: "PSShowNote"), let noted = sheet.cells.first(where: { $0.value.note != nil })?.key {
                controller.grid.hoveredAddress = noted
                controller.updateNotePopup()
            }
            if defaults.bool(forKey: "PSCommentCard"), let commented = sheet.cells.first(where: { $0.value.comment != nil })?.key {
                controller.controller.selection = GridSelection(commented)
            }
            if defaults.bool(forKey: "PSShowProtected") { controller.grid.showsProtectedRanges = true }
            if defaults.bool(forKey: "PSShowFormulas") { controller.grid.showsFormulas = true }
            if defaults.bool(forKey: "PSTableSettings"), let table = sheet.tables.first {
                controller.controller.selection = GridSelection(table.range.start)
                controller.showTableSettings(table.id)
            }
            if defaults.bool(forKey: "PSSlicerEditor"), let slicer = sheet.objects.first(where: { $0.slicer != nil }) {
                controller.showSlicerEditor(slicer.id)
            }
            switch defaults.string(forKey: "PSSidebar") {
            case "comments": controller.showSidebar(.comments)
            case "protections": controller.showSidebar(.protections)
            case "columnStats": controller.showSidebar(.columnStats)
            default: break
            }
            if defaults.bool(forKey: "PSFormulaBarEdit") {
                controller.window?.makeFirstResponder(controller.formulaBar.field)
            }
            switch defaults.string(forKey: "PSSidebar") {
            case "conditionalFormatting": controller.showSidebar(.conditionalFormatting)
            case "dataValidation": controller.showSidebar(.dataValidation)
            case "alternatingColors": controller.showSidebar(.alternatingColors)
            case "namedRanges": controller.showSidebar(.namedRanges)
            default: break
            }
            if let column = defaults.object(forKey: "PSFilterColumn") as? String, let index = Int(column),
               let rect = controller.grid.filterButtonRect(column: index) {
                controller.showFilterPopover(column: index, at: rect)
            }
            if defaults.bool(forKey: "PSCollaborationDemo") { CollaborationDemo.start(controller) }
            switch defaults.string(forKey: "PSOpenSheet") {
            case "shortcuts": controller.psShowShortcuts(nil)
            case "collaborate":
                DispatchQueue.main.asyncAfter(deadline: .now() + (defaults.bool(forKey: "PSCollaborationDemo") ? 1.6 : 0)) {
                    controller.showCollaborate()
                }
            default: break
            }
            if defaults.bool(forKey: "PSShowAbout"), let appMenu = NSApp.mainMenu?.items.first?.submenu {
                appMenu.performActionForItem(at: appMenu.indexOfItem(withTitle: "About PuggleSheets"))
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (defaults.bool(forKey: "PSCollaborationDemo") ? 5.0 : 2.5)) {
            guard let documentWindow = NSApp.windows.first(where: { $0.windowController is DocumentWindowController }),
                  case let about = NSApp.windows.first(where: { $0.windowController is AboutWindowController && $0.isVisible }),
                  case let popover = NSApp.windows.first(where: { String(describing: type(of: $0)).contains("Popover") && $0.isVisible }),
                  case let panel = documentWindow.childWindows?.first(where: { $0 is NSPanel && $0.isVisible && defaults.bool(forKey: "PSSnapshotPanel") }),
                  case let window = about ?? popover ?? panel ?? documentWindow.attachedSheet ?? documentWindow,
                  let view = window.contentView?.superview ?? window.contentView else {
                print("PSSnapshot: no document window")
                NSApp.terminate(nil)
                return
            }
            print("PSSnapshot: window=\(window.frame.size)")
            let bounds = view.bounds
            if let rep = view.bitmapImageRepForCachingDisplay(in: bounds) {
                view.cacheDisplay(in: bounds, to: rep)
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
                print("PSSnapshot: \(url.path)")
            }
            // Exit directly: quitting normally would wait on any open sheet or unsaved-changes prompt.
            fflush(stdout)
            exit(0)
        }
    }
}

/// `-PSCollaborationDemo YES` (with `-PSStandInCloud YES`) shares the window's spreadsheet on the stand-in "iCloud"
/// with two people, who open it, type and comment, for screenshots of a shared spreadsheet. `-PSDemoOffline YES` then
/// takes this Mac offline, to show a shared spreadsheet while iCloud can't be reached.
enum CollaborationDemo {
    static let ana = StandInPerson(Collaborator(id: "ana@example.com", name: "Ana Lopez", address: "ana@example.com"))
    static let ben = StandInPerson(Collaborator(id: "ben@example.com", name: "Ben Carter", address: "ben@example.com"))

    static func start(_ controller: DocumentWindowController) {
        guard let document = controller.spreadsheet else { return }
        SpreadsheetCollaboration.noticeDelay = 3
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Team budget.xlsx")
        document.save(to: url, ofType: SpreadsheetFileFormat.xlsx.typeIdentifier, for: .saveAsOperation) { _ in
            MainActor.assumeIsolated {
                CollaborationController.shared.share(document, in: controller, access: .invited, permission: .edit) { _ in
                    guard let id = document.collaboration?.id else { return }
                    let service = CollaborationController.shared.service
                    service.invite("ana@example.com", permission: .edit, to: id) { result in
                        if case let .success(sharing) = result { document.collaboration?.sharingUpdated(sharing) }
                    }
                    service.invite("ben@example.com", permission: .comment, to: id) { result in
                        if case let .success(sharing) = result { document.collaboration?.sharingUpdated(sharing) }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        ana.join(id)
                        ben.join(id)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        ana.type("Updated by Ana", in: "A1")
                        ben.comment("Can we add a column for next month?", on: "B2")
                    }
                    if UserDefaults.standard.bool(forKey: "PSDemoOffline") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { StandInCloud.shared.isReachable = false }
                    }
                }
            }
        }
    }
}
#endif
