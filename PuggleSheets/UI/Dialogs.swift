import SwiftUI

/// Help ▸ Keyboard shortcuts: the shortcuts PuggleSheets supports.
struct ShortcutsView: View {
    let dismiss: () -> Void

    private let columns: [[(String, [(String, String)])]] = [
        [
            ("Moving around", [
                ("Move to the edge of the data", "⌘ arrow"),
                ("Extend the selection", "⇧ arrow"),
                ("Extend to the edge of the data", "⇧⌘ arrow"),
                ("Go to A1 / the last cell with data", "⌘↖ / ⌘↘"),
                ("Next / previous sheet", "⌥↓ / ⌥↑"),
                ("Select row / column", "⇧Space / ⌃Space"),
                ("Select all", "⌘A"),
            ]),
            ("Entering data", [
                ("Edit the active cell", "Return or F2"),
                ("Line break in a cell", "⌥Return"),
                ("Enter into every selected cell", "⌘Return"),
                ("Cancel an entry", "Esc"),
                ("Clear the selected cells", "Delete"),
                ("Fill down / fill right", "⌘D / ⌘R"),
                ("Insert date / time / date and time", "⌘; / ⇧⌘; / ⌥⇧⌘;"),
            ]),
        ],
        [
            ("Formatting", [
                ("Bold / italic / underline", "⌘B / ⌘I / ⌘U"),
                ("Strikethrough", "⇧⌘X"),
                ("Align left / center / right", "⇧⌘L / ⇧⌘E / ⇧⌘R"),
                ("Number / time / date format", "⇧⌘1 / ⇧⌘2 / ⇧⌘3"),
                ("Currency / percent / scientific", "⇧⌘4 / ⇧⌘5 / ⇧⌘6"),
                ("Bigger / smaller text", "⇧⌘. / ⇧⌘,"),
                ("Clear formatting", "⌘\\"),
            ]),
            ("Editing", [
                ("Undo / redo", "⌘Z / ⇧⌘Z"),
                ("Cut / copy / paste", "⌘X / ⌘C / ⌘V"),
                ("Paste values only", "⇧⌘V"),
                ("Paste format only", "⌥⌘V"),
                ("Find / find and replace", "⌘F / ⇧⌘H"),
                ("Insert link", "⌘K"),
                ("Insert comment / note", "⌥⌘M / ⇧F2"),
                ("Collaborate", "⌥⌘C"),
                ("Show formulas", "⌃`"),
                ("Group / ungroup", "⌥⇧→ / ⌥⇧←"),
                ("Convert to table", "⌥⌘T"),
                ("Print", "⌘P"),
                ("Insert a sheet", "⇧F11"),
                ("Zoom in / out / actual size", "⌘= / ⌘- / ⌘0"),
            ]),
        ],
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Keyboard shortcuts").font(.system(size: 20))
            HStack(alignment: .top, spacing: 36) {
                ForEach(0..<columns.count, id: \.self) { column in
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(0..<columns[column].count, id: \.self) { index in
                            let group = columns[column][index]
                            VStack(alignment: .leading, spacing: 6) {
                                Text(group.0).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.secondaryText)
                                ForEach(0..<group.1.count, id: \.self) { row in
                                    HStack {
                                        Text(group.1[row].0).font(.system(size: 13))
                                        Spacer(minLength: 16)
                                        Text(group.1[row].1).font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.secondaryText)
                                    }
                                }
                            }
                        }
                    }
                    .frame(width: 330)
                }
            }
            HStack {
                Spacer()
                Button("Close", action: dismiss).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .fixedSize()
    }
}
