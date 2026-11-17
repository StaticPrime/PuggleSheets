import Foundation
import Testing
@testable import PuggleSheetsKit

/// What a test puts in a cell: "=…" strings are formulas, other literals are values.
enum CellInput: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral {
    case value(CellValue)
    case formula(String)

    init(stringLiteral text: String) {
        self = text.hasPrefix("=") ? .formula(text) : .value(.text(text))
    }

    init(integerLiteral number: Int) { self = .value(.number(Double(number))) }
    init(floatLiteral number: Double) { self = .value(.number(number)) }
    init(booleanLiteral boolean: Bool) { self = .value(.boolean(boolean)) }

    static let empty = CellInput.value(.empty)

    static func error(_ kind: CellError.Kind) -> CellInput { .value(.error(CellError(kind))) }

    var cell: Cell {
        switch self {
        case .value(let value): Cell(value: value)
        case .formula(let formula): Cell(formula: formula)
        }
    }
}

/// A workbook with an engine, for recalculation tests.
struct TestBook {
    var workbook: Workbook
    let engine = FormulaEngine()
    var now: Date

    init(_ sheets: [(name: String, cells: [String: CellInput])], now: Date = Date(timeIntervalSince1970: 1_790_000_000)) {
        workbook = Workbook(sheets: sheets.map { entry in
            var sheet = Sheet(name: entry.name)
            for (a1, input) in entry.cells { sheet[CellAddress(a1: a1)!] = input.cell }
            return sheet
        })
        self.now = now
        engine.recalculateAll(&workbook, now: now)
    }

    init(_ cells: [String: CellInput] = [:]) {
        self.init([("Sheet1", cells)])
    }

    func value(_ a1: String, sheet: Int = 0) -> CellValue {
        workbook.sheets[sheet][CellAddress(a1: a1)!].value
    }

    subscript(_ a1: String) -> CellValue { value(a1) }

    /// Sets cells and recalculates incrementally.
    mutating func set(_ cells: [String: CellInput], sheet: Int = 0) {
        var changed: [SheetCell] = []
        for (a1, input) in cells {
            let address = CellAddress(a1: a1)!
            var cell = workbook.sheets[sheet][address]
            cell.formula = nil
            cell.value = .empty
            switch input {
            case .value(let value): cell.value = value
            case .formula(let formula): cell.formula = formula
            }
            workbook.sheets[sheet][address] = cell
            changed.append(SheetCell(sheet: workbook.sheets[sheet].id, address: address))
        }
        engine.recalculate(&workbook, changed: changed, now: now)
    }

    mutating func set(_ a1: String, _ input: CellInput, sheet: Int = 0) {
        set([a1: input], sheet: sheet)
    }

    func evaluate(_ formula: String, at a1: String = "Z100", sheet: Int = 0) -> CellValue {
        FormulaEngine.evaluate(formula, inSheet: sheet, at: CellAddress(a1: a1)!, workbook: workbook, now: now)
    }
}

/// Evaluates a formula against a sheet holding `cells` (formulas among them are computed first).
func eval(_ formula: String, _ cells: [String: CellInput] = [:], at a1: String = "Z100") -> CellValue {
    TestBook(cells).evaluate(formula, at: a1)
}

func err(_ kind: CellError.Kind) -> CellValue { .error(CellError(kind)) }

func num(_ value: CellValue) -> Double? { value.numberValue }

/// True when `value` is a number within `tolerance` of `expected`.
func close(_ value: CellValue, _ expected: Double, tolerance: Double = 1e-9) -> Bool {
    guard case .number(let number) = value else { return false }
    return abs(number - expected) <= tolerance * max(1, abs(expected))
}

/// The message of an error value.
func message(_ value: CellValue) -> String? { value.errorValue?.message }
