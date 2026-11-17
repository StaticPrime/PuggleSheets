import AppKit
import PuggleSheetsKit

/// Native menus opened from toolbar dropdowns.
enum ToolbarMenus {
    /// Fonts offered in the font menu, shown when installed.
    static let featuredFonts = ["Arial", "Comic Sans MS", "Courier New", "Georgia", "Helvetica", "Impact", "Times New Roman",
                                "Trebuchet MS", "Verdana"]

    static func make(_ kind: ToolbarMenu, controller: DocumentWindowController) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = true
        let state = controller.state
        let format = state.summary.format
        func add(_ item: NSMenuItem) {
            if item.action != nil && item.target == nil { item.target = controller }
            menu.addItem(item)
        }

        switch kind {
        case .zoom:
            for level in Theme.zoomLevels {
                let item = MenuBuilder.item("\(Int(level * 100))%", #selector(SheetCommands.psSetZoom(_:)), tag: Int(level * 100))
                item.state = abs(state.zoom - level) < 0.005 ? .on : .off
                add(item)
            }

        case .numberFormats:
            for item in MenuBuilder.numberFormatItems() {
                if item.action == #selector(SheetCommands.psNumberFormat(_:)) {
                    let preset = NumberFormatPresets.all[item.tag]
                    item.state = preset.pattern == format.numberFormat ? .on : .off
                }
                add(item)
            }

        case .font:
            add(MenuBuilder.item("More fonts…", #selector(SheetCommands.psMoreFonts(_:)), symbol: "textformat"))
            menu.addItem(.separator())
            let installed = Set(NSFontManager.shared.availableFontFamilies)
            for family in featuredFonts where installed.contains(family) {
                let item = MenuBuilder.item(family, #selector(SheetCommands.psSetFont(_:)))
                item.representedObject = family
                item.attributedTitle = NSAttributedString(string: family, attributes: [.font: NSFont(name: family, size: 14) ?? NSFont.systemFont(ofSize: 14)])
                item.state = family == format.resolvedFontFamily ? .on : .off
                add(item)
            }

        case .merge:
            for item in MenuBuilder.mergeItems() { add(item) }

        case .horizontalAlign:
            for item in MenuBuilder.alignmentItems().prefix(3) {
                item.keyEquivalent = ""
                let current = format.horizontalAlignment.map { [HorizontalAlignment.left, .center, .right].firstIndex(of: $0) ?? -1 } ?? -1
                item.state = item.tag == current ? .on : .off
                add(item)
            }

        case .verticalAlign:
            for item in MenuBuilder.alignmentItems().suffix(3) {
                let current = [VerticalAlignment.top, .middle, .bottom].firstIndex(of: format.resolvedVerticalAlignment) ?? 2
                item.state = item.tag == current ? .on : .off
                add(item)
            }

        case .wrap:
            for item in MenuBuilder.wrapItems() {
                let current = [WrapStrategy.overflow, .wrap, .clip].firstIndex(of: format.resolvedWrap) ?? 0
                item.state = item.tag == current ? .on : .off
                add(item)
            }

        case .rotation:
            for item in MenuBuilder.rotationItems() {
                let current: Int = switch format.textRotation {
                case nil: 0
                case .stacked?: 1000
                case .angle(let degrees)?: [45, -45, 90, -90].contains(degrees) ? degrees : 2000
                }
                item.state = item.tag == current ? .on : .off
                add(item)
            }

        case .functions:
            for item in MenuBuilder.functionItems() {
                item.submenu?.items.forEach { $0.target = controller }
                add(item)
            }

        case .download:
            for item in MenuBuilder.downloadItems() { add(item) }
        }
        return menu
    }
}
