import AppKit
import PuggleSheetsKit
import SwiftUI

/// Data ▸ Data cleanup ▸ Remove duplicates: whether the data has a header row and which columns to compare.
struct RemoveDuplicatesView: View {
    let range: CellRange
    let headers: [Int: String]
    let remove: (_ columns: [Int], _ hasHeader: Bool) -> Void
    let dismiss: () -> Void
    @State private var hasHeader = false
    @State private var chosen: Set<Int> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Remove duplicates").font(.system(size: 20))
            Text("Selected range: \(range.a1)").font(.system(size: 13)).foregroundStyle(Theme.secondaryText)
            Toggle("Data has header row", isOn: $hasHeader).toggleStyle(.checkbox).font(.system(size: 13))
            Text("Columns to analyze").font(.system(size: 13, weight: .medium))
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Select all", isOn: Binding(get: { chosen.count == range.columnCount },
                                                   set: { chosen = $0 ? Set(range.columns) : [] }))
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(range.columns), id: \.self) { column in
                            Toggle(title(column), isOn: Binding(get: { chosen.contains(column) },
                                                                set: { if $0 { chosen.insert(column) } else { chosen.remove(column) } }))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
            }
            .toggleStyle(.checkbox)
            .font(.system(size: 13))
            .padding(10)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.divider))
            HStack {
                Spacer()
                PanelButton(title: "Cancel", primary: false) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                PanelButton(title: "Remove duplicates", isEnabled: !chosen.isEmpty) {
                    dismiss()
                    remove(chosen.sorted(), hasHeader)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 400)
        .onAppear { chosen = Set(range.columns) }
    }

    private func title(_ column: Int) -> String {
        let letter = CellAddress.columnName(column)
        if hasHeader, let header = headers[column], !header.isEmpty { return "Column \(letter) – \(header)" }
        return "Column \(letter)"
    }
}

/// The "Separator" chip shown after splitting text to columns.
struct SplitSeparatorView: View {
    @State var choice: Int
    let resplit: (String?) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("Separator:").font(.system(size: 13)).foregroundStyle(Theme.secondaryText)
            Picker("", selection: $choice) {
                ForEach(Array(SpreadsheetController.splitSeparators.enumerated()), id: \.offset) { index, item in
                    Text(item.title).tag(index)
                }
            }
            .labelsHidden()
            .fixedSize()
            .onChange(of: choice) { _, index in resplit(SpreadsheetController.splitSeparators[index].separator) }
        }
        .padding(10)
    }
}
