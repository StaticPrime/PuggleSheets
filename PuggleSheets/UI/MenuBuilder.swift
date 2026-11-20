import AppKit
import PuggleSheetsKit

/// Actions implemented by `DocumentWindowController` and reached through the responder chain.
@objc protocol SheetCommands {
    func psDownload(_ sender: Any?)
    func psDownloadPDF(_ sender: Any?)
    func psPrint(_ sender: Any?)
    func psRename(_ sender: Any?)
    func psPasteValues(_ sender: Any?)
    func psPasteFormat(_ sender: Any?)
    func psDeleteValues(_ sender: Any?)
    func psDeleteRows(_ sender: Any?)
    func psDeleteColumns(_ sender: Any?)
    func psFillDown(_ sender: Any?)
    func psFillRight(_ sender: Any?)
    func psFind(_ sender: Any?)
    func psFindNext(_ sender: Any?)
    func psFindPrevious(_ sender: Any?)
    func psFindReplace(_ sender: Any?)
    func psToggleGridlines(_ sender: Any?)
    func psToggleFormulaBar(_ sender: Any?)
    func psFreezeRows(_ sender: Any?)
    func psFreezeColumns(_ sender: Any?)
    func psSetZoom(_ sender: Any?)
    func psZoomIn(_ sender: Any?)
    func psZoomOut(_ sender: Any?)
    func psActualSize(_ sender: Any?)
    func psInsertRowsAbove(_ sender: Any?)
    func psInsertRowsBelow(_ sender: Any?)
    func psInsertColumnsLeft(_ sender: Any?)
    func psInsertColumnsRight(_ sender: Any?)
    func psInsertSheet(_ sender: Any?)
    func psInsertFunction(_ sender: Any?)
    func psInsertDate(_ sender: Any?)
    func psInsertTime(_ sender: Any?)
    func psInsertDateTime(_ sender: Any?)
    func psNumberFormat(_ sender: Any?)
    func psCustomNumberFormat(_ sender: Any?)
    func psToggleBold(_ sender: Any?)
    func psToggleItalic(_ sender: Any?)
    func psToggleUnderline(_ sender: Any?)
    func psToggleStrikethrough(_ sender: Any?)
    func psAlignHorizontal(_ sender: Any?)
    func psAlignVertical(_ sender: Any?)
    func psWrap(_ sender: Any?)
    func psIncreaseFontSize(_ sender: Any?)
    func psDecreaseFontSize(_ sender: Any?)
    func psSetFont(_ sender: Any?)
    func psMoreFonts(_ sender: Any?)
    func psMerge(_ sender: Any?)
    func psClearFormatting(_ sender: Any?)
    func psSortSheet(_ sender: Any?)
    func psSortRange(_ sender: Any?)
    func psHideRows(_ sender: Any?)
    func psHideColumns(_ sender: Any?)
    func psUnhideRows(_ sender: Any?)
    func psUnhideColumns(_ sender: Any?)
    func psResizeColumns(_ sender: Any?)
    func psResizeRows(_ sender: Any?)
    func psDuplicateSheet(_ sender: Any?)
    func psDeleteSheet(_ sender: Any?)
    func psRenameSheet(_ sender: Any?)
    func psNextSheet(_ sender: Any?)
    func psPreviousSheet(_ sender: Any?)
    func psShowShortcuts(_ sender: Any?)
    func psConditionalFormatting(_ sender: Any?)
    func psAlternatingColors(_ sender: Any?)
    func psDataValidation(_ sender: Any?)
    func psNamedRanges(_ sender: Any?)
    func psInsertCheckbox(_ sender: Any?)
    func psConvertToTable(_ sender: Any?)
    func psAddSlicer(_ sender: Any?)
    func psInsertNote(_ sender: Any?)
    func psClearNotes(_ sender: Any?)
    func psInsertComment(_ sender: Any?)
    func psCollaborate(_ sender: Any?)
    func psLeaveShared(_ sender: Any?)
    func psShowComments(_ sender: Any?)
    func psProtect(_ sender: Any?)
    func psToggleShowProtectedRanges(_ sender: Any?)
    func psToggleShowFormulas(_ sender: Any?)
    func psGroup(_ sender: Any?)
    func psUngroup(_ sender: Any?)
    func psGroupRows(_ sender: Any?)
    func psUngroupRows(_ sender: Any?)
    func psGroupColumns(_ sender: Any?)
    func psUngroupColumns(_ sender: Any?)
    func psExpandAllGroups(_ sender: Any?)
    func psCollapseAllGroups(_ sender: Any?)
    func psRotation(_ sender: Any?)
    func psRandomizeRange(_ sender: Any?)
    func psColumnStats(_ sender: Any?)
    func psPasteTransposed(_ sender: Any?)
    func psImport(_ sender: Any?)
    func psInsertChart(_ sender: Any?)
    func psInsertPivotTable(_ sender: Any?)
    func psInsertImageInCell(_ sender: Any?)
    func psInsertImageOverCells(_ sender: Any?)
    func psInsertLink(_ sender: Any?)
    func psCreateFilterView(_ sender: Any?)
    func psSaveFilterAsView(_ sender: Any?)
    func psOpenFilterView(_ sender: Any?)
    func psCloseFilterView(_ sender: Any?)
    func psInsertCellsShiftRight(_ sender: Any?)
    func psInsertCellsShiftDown(_ sender: Any?)
    func psDeleteCellsShiftLeft(_ sender: Any?)
    func psDeleteCellsShiftUp(_ sender: Any?)
    func psSplitTextToColumns(_ sender: Any?)
    func psRemoveDuplicates(_ sender: Any?)
    func psTrimWhitespace(_ sender: Any?)
    func psInsertDropdown(_ sender: Any?)
    func psToggleFilter(_ sender: Any?)
}

enum MenuKind: String, CaseIterable {
    case file = "File", edit = "Edit", view = "View", insert = "Insert", format = "Format", data = "Data", help = "Help"
}

enum MenuBuilder {
    static func item(_ title: String, _ action: Selector?, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command,
                     tag: Int = 0, symbol: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        item.tag = tag
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }

    static func submenu(_ title: String, symbol: String? = nil, _ items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        item.submenu = menu
        return item
    }

    /// Data ▸ Filter views, listing the active sheet's views each time it opens.
    private static func filterViewsItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Filter views", action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "line.3.horizontal.decrease.circle", accessibilityDescription: nil)
        let menu = NSMenu(title: "Filter views")
        menu.delegate = FilterViewsMenu.shared
        item.submenu = menu
        return item
    }

    static func makeMainMenu() -> NSMenu {
        let main = NSMenu(title: "Main")
        let appItem = NSMenuItem()
        appItem.submenu = makeAppMenu()
        main.addItem(appItem)
        for kind in MenuKind.allCases where kind != .help {
            let item = NSMenuItem(title: kind.rawValue, action: nil, keyEquivalent: "")
            item.submenu = makeMenu(kind)
            main.addItem(item)
        }
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        let windowMenu = makeWindowMenu()
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu
        let helpItem = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        let helpMenu = makeMenu(.help)
        helpItem.submenu = helpMenu
        main.addItem(helpItem)
        NSApp.helpMenu = helpMenu
        return main
    }

    static func makeAppMenu() -> NSMenu {
        let menu = NSMenu(title: "PuggleSheets")
        menu.addItem(item("About PuggleSheets", #selector(AppDelegate.showAboutWindow(_:))))
        menu.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        services.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        menu.addItem(services)
        menu.addItem(.separator())
        menu.addItem(item("Hide PuggleSheets", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Quit PuggleSheets", #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    static func makeWindowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }

    static func makeMenu(_ kind: MenuKind) -> NSMenu {
        let menu = NSMenu(title: kind.rawValue)
        let items: [NSMenuItem]
        switch kind {
        case .file: items = fileItems()
        case .edit: items = editItems()
        case .view: items = viewItems()
        case .insert: items = insertItems()
        case .format: items = formatItems()
        case .data: items = dataItems()
        case .help: items = [item("Keyboard shortcuts", #selector(SheetCommands.psShowShortcuts(_:)), "/", symbol: "keyboard")]
        }
        items.forEach(menu.addItem)
        return menu
    }

    static func downloadItems() -> [NSMenuItem] {
        SpreadsheetFileFormat.allCases.enumerated().map { index, format in
            item(format.displayName, #selector(SheetCommands.psDownload(_:)), tag: index)
        } + [item("PDF (.pdf)", #selector(SheetCommands.psDownloadPDF(_:)))]
    }

    private static func fileItems() -> [NSMenuItem] {
        [
            item("New spreadsheet", #selector(NSDocumentController.newDocument(_:)), "n", symbol: "plus.square"),
            item("Open…", #selector(NSDocumentController.openDocument(_:)), "o", symbol: "folder"),
            item("Import…", #selector(SheetCommands.psImport(_:)), symbol: "square.and.arrow.down.on.square"),
            .separator(),
            item("Make a copy", #selector(NSDocument.duplicate(_:)), "s", [.command, .shift], symbol: "plus.square.on.square"),
            .separator(),
            item("Collaborate…", #selector(SheetCommands.psCollaborate(_:)), "c", [.command, .option], symbol: "person.2"),
            item("Leave shared spreadsheet…", #selector(SheetCommands.psLeaveShared(_:)), symbol: "rectangle.portrait.and.arrow.right"),
            sharedSpreadsheetsMenu(),
            .separator(),
            item("Save", #selector(NSDocument.save(_:)), "s", symbol: "square.and.arrow.down"),
            submenu("Download", symbol: "arrow.down.to.line", downloadItems()),
            item("Rename", #selector(SheetCommands.psRename(_:)), symbol: "pencil"),
            item("Move…", #selector(NSDocument.move(_:)), symbol: "folder.badge.gearshape"),
            .separator(),
            submenu("Version history", symbol: "clock.arrow.circlepath", [
                item("See version history", #selector(NSDocument.browseVersions(_:))),
                item("Revert to last saved", #selector(NSDocument.revertToSaved(_:))),
            ]),
            .separator(),
            item("Print", #selector(SheetCommands.psPrint(_:)), "p", symbol: "printer"),
            .separator(),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
        ]
    }

    /// File ▸ Shared spreadsheets: those shared with this person, and theirs that are shared, filled in as it opens.
    private static func sharedSpreadsheetsMenu() -> NSMenuItem {
        let item = submenu("Shared spreadsheets", symbol: "person.2.circle", [])
        item.submenu?.delegate = SharedSpreadsheetsMenu.shared
        return item
    }

    private static func editItems() -> [NSMenuItem] {
        [
            item("Undo", Selector(("undo:")), "z", symbol: "arrow.uturn.backward"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift], symbol: "arrow.uturn.forward"),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x", symbol: "scissors"),
            item("Copy", #selector(NSText.copy(_:)), "c", symbol: "doc.on.doc"),
            item("Paste", #selector(NSText.paste(_:)), "v", symbol: "doc.on.clipboard"),
            submenu("Paste special", symbol: "doc.on.clipboard", [
                item("Values only", #selector(SheetCommands.psPasteValues(_:)), "v", [.command, .shift]),
                item("Format only", #selector(SheetCommands.psPasteFormat(_:)), "v", [.command, .option]),
                item("Transposed", #selector(SheetCommands.psPasteTransposed(_:))),
            ]),
            .separator(),
            submenu("Delete", symbol: "trash", [
                item("Values", #selector(SheetCommands.psDeleteValues(_:))),
                item("Row", #selector(SheetCommands.psDeleteRows(_:))),
                item("Column", #selector(SheetCommands.psDeleteColumns(_:))),
                .separator(),
                item("Cells and shift left", #selector(SheetCommands.psDeleteCellsShiftLeft(_:))),
                item("Cells and shift up", #selector(SheetCommands.psDeleteCellsShiftUp(_:))),
            ]),
            item("Fill down", #selector(SheetCommands.psFillDown(_:)), "d"),
            item("Fill right", #selector(SheetCommands.psFillRight(_:)), "r"),
            .separator(),
            item("Select all", #selector(NSResponder.selectAll(_:)), "a"),
            .separator(),
            item("Find", #selector(SheetCommands.psFind(_:)), "f", symbol: "magnifyingglass"),
            item("Find next", #selector(SheetCommands.psFindNext(_:)), "g"),
            item("Find previous", #selector(SheetCommands.psFindPrevious(_:)), "g", [.command, .shift]),
            item("Find and replace", #selector(SheetCommands.psFindReplace(_:)), "h", [.command, .shift]),
            .separator(),
            item("Emoji & Symbols", #selector(NSApplication.orderFrontCharacterPalette(_:)), " ", [.command, .control]),
        ]
    }

    static func freezeItems() -> [NSMenuItem] {
        [
            item("No rows", #selector(SheetCommands.psFreezeRows(_:)), tag: 0),
            item("1 row", #selector(SheetCommands.psFreezeRows(_:)), tag: 1),
            item("2 rows", #selector(SheetCommands.psFreezeRows(_:)), tag: 2),
            item("Up to current row", #selector(SheetCommands.psFreezeRows(_:)), tag: -1),
            .separator(),
            item("No columns", #selector(SheetCommands.psFreezeColumns(_:)), tag: 0),
            item("1 column", #selector(SheetCommands.psFreezeColumns(_:)), tag: 1),
            item("2 columns", #selector(SheetCommands.psFreezeColumns(_:)), tag: 2),
            item("Up to current column", #selector(SheetCommands.psFreezeColumns(_:)), tag: -1),
        ]
    }

    private static func viewItems() -> [NSMenuItem] {
        [
            submenu("Show", symbol: "eye", [
                item("Gridlines", #selector(SheetCommands.psToggleGridlines(_:))),
                item("Formula bar", #selector(SheetCommands.psToggleFormulaBar(_:))),
                item("Formulas", #selector(SheetCommands.psToggleShowFormulas(_:)), "`", [.control]),
                item("Protected ranges", #selector(SheetCommands.psToggleShowProtectedRanges(_:))),
            ]),
            submenu("Freeze", symbol: "rectangle.topthird.inset.filled", freezeItems()),
            submenu("Group", symbol: "rectangle.3.group", [
                item("Group", #selector(SheetCommands.psGroup(_:)), String(UnicodeScalar(NSRightArrowFunctionKey)!), [.option, .shift]),
                item("Ungroup", #selector(SheetCommands.psUngroup(_:)), String(UnicodeScalar(NSLeftArrowFunctionKey)!), [.option, .shift]),
                .separator(),
                item("Group rows", #selector(SheetCommands.psGroupRows(_:))),
                item("Ungroup rows", #selector(SheetCommands.psUngroupRows(_:))),
                item("Group columns", #selector(SheetCommands.psGroupColumns(_:))),
                item("Ungroup columns", #selector(SheetCommands.psUngroupColumns(_:))),
                .separator(),
                item("Expand all groups", #selector(SheetCommands.psExpandAllGroups(_:))),
                item("Collapse all groups", #selector(SheetCommands.psCollapseAllGroups(_:))),
            ]),
            item("Comments", #selector(SheetCommands.psShowComments(_:)), symbol: "text.bubble"),
            .separator(),
            item("Zoom in", #selector(SheetCommands.psZoomIn(_:)), "="),
            item("Zoom out", #selector(SheetCommands.psZoomOut(_:)), "-"),
            item("Actual size", #selector(SheetCommands.psActualSize(_:)), "0"),
            submenu("Zoom", symbol: "plus.magnifyingglass", Theme.zoomLevels.map {
                item("\(Int($0 * 100))%", #selector(SheetCommands.psSetZoom(_:)), tag: Int($0 * 100))
            }),
            .separator(),
            item("Full screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ]
    }

    static func functionItems() -> [NSMenuItem] {
        var items = ["SUM", "AVERAGE", "COUNT", "MAX", "MIN"].map { name -> NSMenuItem in
            let menuItem = item(name, #selector(SheetCommands.psInsertFunction(_:)))
            menuItem.representedObject = name
            return menuItem
        }
        let all = FormulaEngine.functionNames
        if !all.isEmpty {
            items.append(.separator())
            items.append(submenu("All", all.map { name in
                let menuItem = item(name, #selector(SheetCommands.psInsertFunction(_:)))
                menuItem.representedObject = name
                return menuItem
            }))
        }
        return items
    }

    private static func insertItems() -> [NSMenuItem] {
        [
            item("Rows above", #selector(SheetCommands.psInsertRowsAbove(_:)), symbol: "arrow.up.to.line"),
            item("Rows below", #selector(SheetCommands.psInsertRowsBelow(_:)), symbol: "arrow.down.to.line"),
            item("Columns left", #selector(SheetCommands.psInsertColumnsLeft(_:)), symbol: "arrow.left.to.line"),
            item("Columns right", #selector(SheetCommands.psInsertColumnsRight(_:)), symbol: "arrow.right.to.line"),
            submenu("Cells", symbol: "square.grid.3x3.topleft.filled", [
                item("Insert cells and shift right", #selector(SheetCommands.psInsertCellsShiftRight(_:))),
                item("Insert cells and shift down", #selector(SheetCommands.psInsertCellsShiftDown(_:))),
            ]),
            .separator(),
            item("Sheet", #selector(SheetCommands.psInsertSheet(_:)), String(UnicodeScalar(NSF11FunctionKey)!), [.shift], symbol: "plus.rectangle.on.rectangle"),
            .separator(),
            item("Chart", #selector(SheetCommands.psInsertChart(_:)), symbol: "chart.bar"),
            item("Pivot table", #selector(SheetCommands.psInsertPivotTable(_:)), symbol: "tablecells.badge.ellipsis"),
            submenu("Image", symbol: "photo", [
                item("Insert image in cell", #selector(SheetCommands.psInsertImageInCell(_:))),
                item("Insert image over cells", #selector(SheetCommands.psInsertImageOverCells(_:))),
            ]),
            .separator(),
            submenu("Function", symbol: "sum", functionItems()),
            submenu("Date and time", symbol: "calendar", [
                item("Date", #selector(SheetCommands.psInsertDate(_:)), ";"),
                item("Time", #selector(SheetCommands.psInsertTime(_:)), ";", [.command, .shift]),
                item("Date and time", #selector(SheetCommands.psInsertDateTime(_:)), ";", [.command, .option, .shift]),
            ]),
            .separator(),
            item("Link", #selector(SheetCommands.psInsertLink(_:)), "k", symbol: "link"),
            item("Comment", #selector(SheetCommands.psInsertComment(_:)), "m", [.command, .option], symbol: "text.bubble"),
            item("Note", #selector(SheetCommands.psInsertNote(_:)), String(UnicodeScalar(NSF2FunctionKey)!), [.shift], symbol: "note.text"),
            item("Checkbox", #selector(SheetCommands.psInsertCheckbox(_:)), symbol: "checkmark.square"),
            item("Dropdown", #selector(SheetCommands.psInsertDropdown(_:)), symbol: "chevron.down.circle"),
            .separator(),
            item("Special characters", #selector(NSApplication.orderFrontCharacterPalette(_:)), symbol: "character.textbox"),
        ]
    }

    /// Format ▸ Number, with ⇧⌘1–6 shortcuts.
    static func numberFormatItems() -> [NSMenuItem] {
        let shortcuts: [String: String] = ["Number": "1", "Time": "2", "Date": "3", "Currency": "4", "Percent": "5", "Scientific": "6"]
        return NumberFormatPresets.all.enumerated().flatMap { index, preset -> [NSMenuItem] in
            let menuItem = item(preset.name, #selector(SheetCommands.psNumberFormat(_:)), shortcuts[preset.name] ?? "", [.command, .shift], tag: index)
            if #available(macOS 14.4, *), !preset.example.isEmpty { menuItem.subtitle = preset.example }
            return index == 1 || index == 2 || index == 9 ? [.separator(), menuItem] : [menuItem]
        } + [.separator(), item("Custom number format…", #selector(SheetCommands.psCustomNumberFormat(_:)))]
    }

    static func alignmentItems() -> [NSMenuItem] {
        [
            item("Left", #selector(SheetCommands.psAlignHorizontal(_:)), "l", [.command, .shift], tag: 0, symbol: "text.alignleft"),
            item("Center", #selector(SheetCommands.psAlignHorizontal(_:)), "e", [.command, .shift], tag: 1, symbol: "text.aligncenter"),
            item("Right", #selector(SheetCommands.psAlignHorizontal(_:)), "r", [.command, .shift], tag: 2, symbol: "text.alignright"),
            .separator(),
            item("Top", #selector(SheetCommands.psAlignVertical(_:)), tag: 0, symbol: "align.vertical.top"),
            item("Middle", #selector(SheetCommands.psAlignVertical(_:)), tag: 1, symbol: "align.vertical.center"),
            item("Bottom", #selector(SheetCommands.psAlignVertical(_:)), tag: 2, symbol: "align.vertical.bottom"),
        ]
    }

    static func wrapItems() -> [NSMenuItem] {
        [
            item("Overflow", #selector(SheetCommands.psWrap(_:)), tag: 0, symbol: "arrow.forward.to.line"),
            item("Wrap", #selector(SheetCommands.psWrap(_:)), tag: 1, symbol: "arrow.turn.down.left"),
            item("Clip", #selector(SheetCommands.psWrap(_:)), tag: 2, symbol: "arrow.right.to.line.compact"),
        ]
    }

    /// Format ▸ Rotation and the toolbar's rotation menu (tags are angles; 1000 stacks, 2000 asks).
    static func rotationItems() -> [NSMenuItem] {
        [
            item("None", #selector(SheetCommands.psRotation(_:)), tag: 0),
            item("Tilt up", #selector(SheetCommands.psRotation(_:)), tag: 45),
            item("Tilt down", #selector(SheetCommands.psRotation(_:)), tag: -45),
            item("Stack vertically", #selector(SheetCommands.psRotation(_:)), tag: 1000),
            item("Rotate up", #selector(SheetCommands.psRotation(_:)), tag: 90),
            item("Rotate down", #selector(SheetCommands.psRotation(_:)), tag: -90),
            .separator(),
            item("Custom angle…", #selector(SheetCommands.psRotation(_:)), tag: 2000),
        ]
    }

    static func mergeItems() -> [NSMenuItem] {
        MergeKind.allCases.map { item($0.title, #selector(SheetCommands.psMerge(_:)), tag: $0.rawValue) }
    }

    private static func formatItems() -> [NSMenuItem] {
        [
            submenu("Number", symbol: "textformat.123", numberFormatItems()),
            submenu("Text", symbol: "bold", [
                item("Bold", #selector(SheetCommands.psToggleBold(_:)), "b", symbol: "bold"),
                item("Italic", #selector(SheetCommands.psToggleItalic(_:)), "i", symbol: "italic"),
                item("Underline", #selector(SheetCommands.psToggleUnderline(_:)), "u", symbol: "underline"),
                item("Strikethrough", #selector(SheetCommands.psToggleStrikethrough(_:)), "x", [.command, .shift], symbol: "strikethrough"),
            ]),
            submenu("Alignment", symbol: "text.alignleft", alignmentItems()),
            submenu("Wrapping", symbol: "arrow.turn.down.left", wrapItems()),
            submenu("Rotation", symbol: "textformat.alt", rotationItems()),
            submenu("Font size", symbol: "textformat.size", [
                item("Increase font size", #selector(SheetCommands.psIncreaseFontSize(_:)), ".", [.command, .shift]),
                item("Decrease font size", #selector(SheetCommands.psDecreaseFontSize(_:)), ",", [.command, .shift]),
            ]),
            submenu("Merge cells", symbol: "arrow.right.and.line.vertical.and.arrow.left", mergeItems()),
            .separator(),
            item("Convert to table", #selector(SheetCommands.psConvertToTable(_:)), "t", [.command, .option], symbol: "tablecells"),
            .separator(),
            item("Conditional formatting", #selector(SheetCommands.psConditionalFormatting(_:)), symbol: "paintpalette"),
            item("Alternating colors", #selector(SheetCommands.psAlternatingColors(_:)), symbol: "rectangle.split.1x2"),
            .separator(),
            item("Clear formatting", #selector(SheetCommands.psClearFormatting(_:)), "\\", symbol: "textformat"),
        ]
    }

    private static func dataItems() -> [NSMenuItem] {
        [
            item("Create a filter", #selector(SheetCommands.psToggleFilter(_:)), symbol: "line.3.horizontal.decrease"),
            filterViewsItem(),
            item("Add a slicer", #selector(SheetCommands.psAddSlicer(_:)), symbol: "line.3.horizontal.decrease.circle"),
            .separator(),
            item("Named ranges", #selector(SheetCommands.psNamedRanges(_:)), symbol: "tag"),
            item("Data validation", #selector(SheetCommands.psDataValidation(_:)), symbol: "checkmark.shield"),
            item("Protect sheets and ranges", #selector(SheetCommands.psProtect(_:)), symbol: "lock"),
            item("Column stats", #selector(SheetCommands.psColumnStats(_:)), symbol: "chart.bar.doc.horizontal"),
            .separator(),
            item("Sort sheet A to Z", #selector(SheetCommands.psSortSheet(_:)), tag: 0, symbol: "arrow.up"),
            item("Sort sheet Z to A", #selector(SheetCommands.psSortSheet(_:)), tag: 1, symbol: "arrow.down"),
            .separator(),
            item("Sort range A to Z", #selector(SheetCommands.psSortRange(_:)), tag: 0),
            item("Sort range Z to A", #selector(SheetCommands.psSortRange(_:)), tag: 1),
            .separator(),
            item("Randomize range", #selector(SheetCommands.psRandomizeRange(_:)), symbol: "shuffle"),
            submenu("Data cleanup", symbol: "wand.and.stars", [
                item("Remove duplicates", #selector(SheetCommands.psRemoveDuplicates(_:))),
                item("Trim whitespace", #selector(SheetCommands.psTrimWhitespace(_:))),
            ]),
            item("Split text to columns", #selector(SheetCommands.psSplitTextToColumns(_:)), symbol: "rectangle.split.3x1"),
        ]
    }
}

/// Fills Data ▸ Filter views with the key window's views when the menu opens.
final class FilterViewsMenu: NSObject, NSMenuDelegate {
    static let shared = FilterViewsMenu()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(MenuBuilder.item("Create new filter view", #selector(SheetCommands.psCreateFilterView(_:))))
        menu.addItem(MenuBuilder.item("Save as filter view", #selector(SheetCommands.psSaveFilterAsView(_:))))
        guard let window = NSApp.keyWindow?.windowController as? DocumentWindowController else { return }
        let controller = window.controller
        let views = controller.sheet.filterViews
        if !views.isEmpty { menu.addItem(.separator()) }
        for view in views {
            let item = MenuBuilder.item(view.name, #selector(SheetCommands.psOpenFilterView(_:)))
            item.representedObject = view.id
            item.state = controller.activeFilterView?.id == view.id ? .on : .off
            menu.addItem(item)
        }
        if controller.activeFilterView != nil {
            menu.addItem(.separator())
            menu.addItem(MenuBuilder.item("Close filter view", #selector(SheetCommands.psCloseFilterView(_:))))
        }
    }
}

/// Fills File ▸ Shared spreadsheets each time it opens.
final class SharedSpreadsheetsMenu: NSObject, NSMenuDelegate {
    static let shared = SharedSpreadsheetsMenu()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let controller = CollaborationController.shared else { return }
        let others = controller.sharedWithMe
        let mine = controller.mine
        if case let .unavailable(reason) = controller.status {
            let item = NSMenuItem(title: reason, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        if !others.isEmpty {
            menu.addItem(sectionHeader("Shared with you"))
            for entry in others {
                let item = NSMenuItem(title: entry.title, action: #selector(open(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = entry.id.uuidString
                item.toolTip = entry.ownerName.isEmpty ? nil : "Shared by \(entry.ownerName)"
                item.image = NSImage(systemSymbolName: "tablecells", accessibilityDescription: nil)
                menu.addItem(item)
            }
        }
        if !mine.isEmpty {
            if !others.isEmpty { menu.addItem(.separator()) }
            menu.addItem(sectionHeader("Shared by you"))
            for (id, title) in mine {
                let item = NSMenuItem(title: title, action: #selector(open(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = id.uuidString
                item.image = NSImage(systemSymbolName: "person.2", accessibilityDescription: nil)
                menu.addItem(item)
            }
        }
        if others.isEmpty, mine.isEmpty {
            let item = NSMenuItem(title: "No shared spreadsheets", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let link = NSMenuItem(title: "Open Invitation Link…", action: #selector(openLink(_:)), keyEquivalent: "")
        link.target = self
        link.image = NSImage(systemSymbolName: "link", accessibilityDescription: nil)
        menu.addItem(link)
    }

    @objc private func openLink(_ sender: Any?) {
        CollaborationController.shared?.askForInvitationLink()
    }

    private func sectionHeader(_ title: String) -> NSMenuItem {
        if #available(macOS 14, *) { return NSMenuItem.sectionHeader(title: title) }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func open(_ sender: NSMenuItem) {
        guard let controller = CollaborationController.shared, let id = (sender.representedObject as? String).flatMap(UUID.init(uuidString:)) else { return }
        if let entry = controller.sharedWithMe.first(where: { $0.id == id }) {
            controller.openShared(entry)
        } else if let me = controller.status.me {
            controller.openShared(SharedDocumentEntry(id: id, title: sender.title, ownerName: me.name, ownerID: me.id))
        }
    }
}
