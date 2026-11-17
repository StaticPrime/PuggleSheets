import Foundation

/// Help for one function, for autocomplete and the formula help popup.
public struct FormulaFunctionInfo: Hashable, Sendable {
    public var name: String
    /// "SUM(value1, [value2, ...])".
    public var syntax: String
    /// One sentence.
    public var summary: String
    /// "Math", "Statistical", "Logical", "Text", "Lookup", "Date", "Info", "Financial", "Array", "Web" or "Chart".
    public var category: String

    public init(name: String, syntax: String, summary: String, category: String) {
        self.name = name
        self.syntax = syntax
        self.summary = summary
        self.category = category
    }
}

extension FormulaEngine {
    /// Help for every supported function, sorted by name.
    public static var functionInfo: [FormulaFunctionInfo] { FunctionCatalog.all }

    /// Help for one function (case-insensitive name).
    public static func functionInfo(named name: String) -> FormulaFunctionInfo? {
        FunctionCatalog.byName[name.uppercased()]
    }
}

enum FunctionCatalog {
    static let all: [FormulaFunctionInfo] = {
        var result: [FormulaFunctionInfo] = []
        var category = ""
        for line in table.split(separator: "\n") {
            if line.hasPrefix("# ") {
                category = String(line.dropFirst(2))
                continue
            }
            let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 3 else { continue }
            result.append(FormulaFunctionInfo(name: fields[0], syntax: "\(fields[0])(\(fields[1]))", summary: fields[2],
                                              category: category))
        }
        return result.sorted { $0.name < $1.name }
    }()

    static let byName: [String: FormulaFunctionInfo] = Dictionary(all.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

    /// NAME|arguments|summary, grouped by category.
    private static let table = """
    # Math
    ABS|value|Returns the absolute value of a number.
    ACOS|value|Returns the inverse cosine of a value, in radians.
    ACOSH|value|Returns the inverse hyperbolic cosine of a number.
    ASIN|value|Returns the inverse sine of a value, in radians.
    ASINH|value|Returns the inverse hyperbolic sine of a number.
    ATAN|value|Returns the inverse tangent of a value, in radians.
    ATAN2|x, y|Returns the angle between the x-axis and the line from the origin to the point (x, y), in radians.
    ATANH|value|Returns the inverse hyperbolic tangent of a number.
    CEILING|value, [factor]|Rounds a number up to the nearest integer multiple of a specified significance.
    CEILING.MATH|number, [significance], [mode]|Rounds a number up to the nearest multiple of a significance; the mode sets how negative numbers round.
    COMBIN|n, k|Returns the number of ways to choose some number of objects from a pool of a given size.
    COS|angle|Returns the cosine of an angle provided in radians.
    COSH|value|Returns the hyperbolic cosine of any real number.
    DEGREES|angle|Converts an angle value in radians to degrees.
    EVEN|value|Rounds a number up to the nearest even integer.
    EXP|exponent|Returns Euler's number, e (~2.718), raised to a power.
    FACT|value|Returns the factorial of a number.
    FLOOR|value, [factor]|Rounds a number down to the nearest integer multiple of a specified significance.
    FLOOR.MATH|number, [significance], [mode]|Rounds a number down to the nearest multiple of a significance; the mode sets how negative numbers round.
    GCD|value1, [value2, ...]|Returns the greatest common divisor of one or more integers.
    INT|value|Rounds a number down to the nearest integer that is less than or equal to it.
    LCM|value1, [value2, ...]|Returns the least common multiple of one or more integers.
    LN|value|Returns the logarithm of a number, base e (Euler's number).
    LOG|value, [base]|Returns the logarithm of a number given a base.
    LOG10|value|Returns the logarithm of a number, base 10.
    MOD|dividend, divisor|Returns the remainder after a division operation.
    MROUND|value, factor|Rounds one number to the nearest integer multiple of another.
    ODD|value|Rounds a number up to the nearest odd integer.
    PI||Returns the value of Pi.
    POWER|base, exponent|Returns a number raised to a power.
    PRODUCT|factor1, [factor2, ...]|Returns the result of multiplying a series of numbers together.
    QUOTIENT|dividend, divisor|Returns one number divided by another, without the remainder.
    RADIANS|angle|Converts an angle value in degrees to radians.
    RAND||Returns a random number between 0 inclusive and 1 exclusive.
    RANDBETWEEN|low, high|Returns a uniformly random integer between two values, inclusive.
    ROUND|value, [places]|Rounds a number to a certain number of decimal places according to standard rules.
    ROUNDDOWN|value, [places]|Rounds a number to a certain number of decimal places, always rounding down.
    ROUNDUP|value, [places]|Rounds a number to a certain number of decimal places, always rounding up.
    SIGN|value|Returns -1 if a number is negative, 1 if it is positive and 0 if it is zero.
    SIN|angle|Returns the sine of an angle provided in radians.
    SINH|value|Returns the hyperbolic sine of any real number.
    SQRT|value|Returns the positive square root of a positive number.
    SUM|value1, [value2, ...]|Returns the sum of a series of numbers and/or cells.
    SUMIF|range, criterion, [sum_range]|Returns a conditional sum across a range.
    SUMIFS|sum_range, criteria_range1, criterion1, [criteria_range2, criterion2, ...]|Returns the sum of a range depending on multiple criteria.
    SUMPRODUCT|array1, [array2, ...]|Returns the sum of the products of corresponding entries in equal-sized arrays or ranges.
    SUMSQ|value1, [value2, ...]|Returns the sum of the squares of a series of numbers and/or cells.
    TAN|angle|Returns the tangent of an angle provided in radians.
    TANH|value|Returns the hyperbolic tangent of any real number.
    TRUNC|value, [places]|Truncates a number to a certain number of significant digits by omitting less significant digits.
    # Statistical
    AVERAGE|value1, [value2, ...]|Returns the numerical average value in a dataset, ignoring text.
    AVERAGEA|value1, [value2, ...]|Returns the numerical average value in a dataset, counting text as 0.
    AVERAGEIF|criteria_range, criterion, [average_range]|Returns the average of a range depending on criteria.
    AVERAGEIFS|average_range, criteria_range1, criterion1, [criteria_range2, criterion2, ...]|Returns the average of a range depending on multiple criteria.
    CORREL|data_y, data_x|Calculates r, the Pearson product-moment correlation coefficient of a dataset.
    COUNT|value1, [value2, ...]|Returns a count of the number of numeric values in a dataset.
    COUNTA|value1, [value2, ...]|Returns a count of the number of values in a dataset.
    COUNTBLANK|range|Returns the number of empty cells in a given range.
    COUNTIF|range, criterion|Returns a conditional count across a range.
    COUNTIFS|criteria_range1, criterion1, [criteria_range2, criterion2, ...]|Returns the count of a range depending on multiple criteria.
    COUNTUNIQUE|value1, [value2, ...]|Counts the number of unique values in a list of specified values and ranges.
    INTERCEPT|data_y, data_x|Calculates where the line from a linear regression of a dataset crosses the y-axis.
    LARGE|data, n|Returns the nth largest element from a data set.
    MAX|value1, [value2, ...]|Returns the maximum value in a numeric dataset.
    MAXA|value1, [value2, ...]|Returns the maximum numeric value in a dataset, counting text as 0.
    MAXIFS|range, criteria_range1, criterion1, [criteria_range2, criterion2, ...]|Returns the maximum value in a range of cells, filtered by a set of criteria.
    MEDIAN|value1, [value2, ...]|Returns the median value in a numeric dataset.
    MIN|value1, [value2, ...]|Returns the minimum value in a numeric dataset.
    MINA|value1, [value2, ...]|Returns the minimum numeric value in a dataset, counting text as 0.
    MINIFS|range, criteria_range1, criterion1, [criteria_range2, criterion2, ...]|Returns the minimum value in a range of cells, filtered by a set of criteria.
    MODE|value1, [value2, ...]|Returns the most commonly occurring value in a dataset.
    MODE.SNGL|value1, [value2, ...]|Returns the most commonly occurring value in a dataset.
    PERCENTILE|data, percentile|Returns the value at a given percentile of a dataset.
    PERCENTILE.INC|data, percentile|Returns the value at a given percentile of a dataset, 0 and 1 included.
    QUARTILE|data, quartile_number|Returns a value nearest to a specified quartile of a dataset.
    QUARTILE.INC|data, quartile_number|Returns a value nearest to a specified quartile of a dataset.
    RANK|value, data, [is_ascending]|Returns the rank of a specified value in a dataset.
    RANK.AVG|value, data, [is_ascending]|Returns the rank of a specified value in a dataset; tied values get their average rank.
    RANK.EQ|value, data, [is_ascending]|Returns the rank of a specified value in a dataset; tied values get the top rank.
    SLOPE|data_y, data_x|Calculates the slope of the line from a linear regression of a dataset.
    SMALL|data, n|Returns the nth smallest element in a data set.
    STDEV|value1, [value2, ...]|Calculates the standard deviation based on a sample.
    STDEV.P|value1, [value2, ...]|Calculates the standard deviation based on an entire population.
    STDEV.S|value1, [value2, ...]|Calculates the standard deviation based on a sample.
    STDEVP|value1, [value2, ...]|Calculates the standard deviation based on an entire population.
    VAR|value1, [value2, ...]|Calculates the variance based on a sample.
    VAR.P|value1, [value2, ...]|Calculates the variance based on an entire population.
    VAR.S|value1, [value2, ...]|Calculates the variance based on a sample.
    VARP|value1, [value2, ...]|Calculates the variance based on an entire population.
    # Logical
    LAMBDA|[name, ...], formula_expression|Creates and returns a custom function with a set of names and a formula expression that uses them.
    LET|name1, value_expression1, [name2, value_expression2, ...], formula_expression|Assigns names to the results of value expressions and returns the result of the formula expression, which can use those names.
    AND|logical_expression1, [logical_expression2, ...]|Returns true if all of the provided arguments are logically true.
    FALSE||Returns the logical value FALSE.
    IF|logical_expression, value_if_true, [value_if_false]|Returns one value if a logical expression is TRUE and another if it is FALSE.
    IFERROR|value, [value_if_error]|Returns the first argument if it is not an error, otherwise the second argument, or a blank if it is absent.
    IFNA|value, value_if_na|Returns the first argument unless it is the #N/A error, otherwise the second argument.
    IFS|condition1, value1, [condition2, value2, ...]|Returns the value that goes with the first true condition.
    NOT|logical_expression|Returns the opposite of a logical value.
    OR|logical_expression1, [logical_expression2, ...]|Returns true if any of the provided arguments are logically true.
    SWITCH|expression, case1, value1, [case2, value2, ...], [default]|Returns the value that goes with the first case matching an expression, or a default.
    TRUE||Returns the logical value TRUE.
    XOR|logical_expression1, [logical_expression2, ...]|Returns true if an odd number of the provided arguments are logically true.
    # Text
    CHAR|table_number|Converts a number into a character according to the Unicode table.
    CLEAN|text|Returns the text with the non-printable ASCII characters removed.
    CODE|string|Returns the Unicode value of the first character of a string.
    CONCAT|value1, value2|Returns the concatenation of two values.
    CONCATENATE|string1, [string2, ...]|Appends strings to one another.
    EXACT|string1, string2|Tests whether two strings are identical.
    FIND|search_for, text_to_search, [starting_at]|Returns the position at which a string is first found within text, matching case.
    FIXED|number, [number_of_places], [suppress_separator]|Formats a number with a fixed number of decimal places.
    JOIN|delimiter, value_or_array1, [value_or_array2, ...]|Concatenates the elements of one or more arrays using a specified delimiter.
    LEFT|string, [number_of_characters]|Returns a substring from the beginning of a string.
    LEN|text|Returns the length of a string.
    LOWER|text|Converts a string to lowercase.
    MID|string, starting_at, extract_length|Returns a segment of a string.
    PROPER|text_to_capitalize|Capitalizes each word in a string.
    REGEXEXTRACT|text, regular_expression|Extracts the first substring matching a regular expression.
    REGEXMATCH|text, regular_expression|Whether a piece of text matches a regular expression.
    REGEXREPLACE|text, regular_expression, replacement|Replaces the parts of a text that match a regular expression.
    REPLACE|text, position, length, new_text|Replaces part of a text string with a different text string.
    REPT|text_to_repeat, number_of_repetitions|Returns specified text repeated a number of times.
    RIGHT|string, [number_of_characters]|Returns a substring from the end of a string.
    SEARCH|search_for, text_to_search, [starting_at]|Returns the position at which a string is first found within text, ignoring case.
    SPLIT|text, delimiter, [split_by_each], [remove_empty_text]|Divides text around a delimiter and puts each fragment into a separate cell in the row.
    SUBSTITUTE|text_to_search, search_for, replace_with, [occurrence_number]|Replaces existing text with new text in a string.
    T|value|Returns string arguments as text, and an empty string for anything else.
    TEXT|number, format|Converts a number into text according to a specified format.
    TEXTJOIN|delimiter, ignore_empty, text1, [text2, ...]|Combines texts and arrays, with a delimiter separating them.
    TRIM|text|Removes leading, trailing and repeated spaces in text.
    UNICHAR|number|Returns the Unicode character for a number.
    UNICODE|text|Returns the Unicode value of the first character of a text.
    UPPER|text|Converts a string to uppercase.
    VALUE|text|Converts a string in a date, time or number format PuggleSheets understands into a number.
    # Lookup
    GETPIVOTDATA|value_name, any_pivot_table_cell, [original_column, pivot_item, ...]|Extracts an aggregated value from a pivot table that corresponds to the specified row and column headings.
    ADDRESS|row, column, [absolute_relative_mode], [use_a1_notation], [sheet]|Returns a cell reference as a string.
    CHOOSE|index, choice1, [choice2, ...]|Returns an element from a list of choices based on an index.
    COLUMN|[cell_reference]|Returns the column number of a specified cell, with A=1.
    COLUMNS|range|Returns the number of columns in a specified array or range.
    HLOOKUP|search_key, range, index, [is_sorted]|Searches across the first row of a range for a key and returns a cell of the column found.
    INDEX|reference, [row], [column]|Returns the content of a cell, specified by row and column offset.
    INDIRECT|cell_reference_as_string, [is_A1_notation]|Returns a cell reference specified by a string.
    LOOKUP|search_key, search_range, [result_range]|Looks through a sorted row or column for a key and returns the value in the same position of a result range.
    MATCH|search_key, range, [search_type]|Returns the relative position of an item in a range that matches a specified value.
    OFFSET|cell_reference, offset_rows, offset_columns, [height], [width]|Returns a range reference shifted a number of rows and columns from a starting reference.
    ROW|[cell_reference]|Returns the row number of a specified cell.
    ROWS|range|Returns the number of rows in a specified array or range.
    VLOOKUP|search_key, range, index, [is_sorted]|Searches down the first column of a range for a key and returns a cell of the row found.
    XLOOKUP|search_key, lookup_range, result_range, [missing_value], [match_mode], [search_mode]|Returns the values in the result range at the position where a match was found in the lookup range.
    XMATCH|search_key, lookup_range, [match_mode], [search_mode]|Returns the relative position of an item in a range that matches a specified value.
    # Date
    DATE|year, month, day|Converts a year, month, and day into a date.
    DATEDIF|start_date, end_date, unit|Calculates the number of days, months, or years between two dates.
    DATEVALUE|date_string|Converts a date string in a known format to a date value.
    DAY|date|Returns the day of the month that a specific date falls on.
    DAYS|end_date, start_date|Returns the number of days between two dates.
    EDATE|start_date, months|Returns a date a specified number of months before or after another date.
    EOMONTH|start_date, months|Returns the last day of a month a specified number of months before or after another date.
    HOUR|time|Returns the hour component of a specific time.
    ISOWEEKNUM|date|Returns the number of the ISO week of the year where the provided date falls.
    MINUTE|time|Returns the minute component of a specific time.
    MONTH|date|Returns the month of the year a specific date falls in.
    NETWORKDAYS|start_date, end_date, [holidays]|Returns the number of net working days between two dates.
    NOW||Returns the current date and time as a date value.
    SECOND|time|Returns the second component of a specific time.
    TIME|hour, minute, second|Converts an hour, minute, and second into a time.
    TIMEVALUE|time_string|Returns the fraction of a 24-hour day a time represents.
    TODAY||Returns the current date as a date value.
    WEEKDAY|date, [type]|Returns a number representing the day of the week of a date.
    WEEKNUM|date, [type]|Returns a number representing the week of the year where a date falls.
    WORKDAY|start_date, num_days, [holidays]|Calculates the end date after a specified number of working days.
    YEAR|date|Returns the year specified by a given date.
    YEARFRAC|start_date, end_date, [day_count_convention]|Returns the number of years, including fractional years, between two dates.
    # Info
    ISOMITTED|argument|Checks whether the value in a LAMBDA is missing and returns TRUE or FALSE.
    ERROR.TYPE|reference|Returns a number corresponding to an error value.
    ISBLANK|value|Checks whether the referenced cell is empty.
    ISERR|value|Checks whether a value is an error other than #N/A.
    ISERROR|value|Checks whether a value is an error.
    ISEVEN|value|Checks whether the provided value is even.
    ISLOGICAL|value|Checks whether a value is TRUE or FALSE.
    ISNA|value|Checks whether a value is the error #N/A.
    ISNONTEXT|value|Checks whether a value is non-textual.
    ISNUMBER|value|Checks whether a value is a number.
    ISODD|value|Checks whether the provided value is odd.
    ISREF|value|Checks whether a value is a valid cell reference.
    ISTEXT|value|Checks whether a value is text.
    N|value|Returns the argument provided as a number.
    NA||Returns the "value not available" error, #N/A.
    TYPE|value|Returns a number associated with the type of data passed into the function.
    # Financial
    FV|rate, number_of_periods, payment_amount, [present_value], [end_or_beginning]|Calculates the future value of an annuity investment with constant payments and interest rate.
    IRR|cashflow_amounts, [rate_guess]|Calculates the internal rate of return on an investment based on a series of periodic cash flows.
    NPER|rate, payment_amount, present_value, [future_value], [end_or_beginning]|Calculates the number of payment periods of an investment with constant payments and interest rate.
    NPV|discount, cashflow1, [cashflow2, ...]|Calculates the net present value of an investment based on a series of periodic cash flows.
    PMT|rate, number_of_periods, present_value, [future_value], [end_or_beginning]|Calculates the periodic payment of an annuity investment with a constant interest rate.
    PV|rate, number_of_periods, payment_amount, [future_value], [end_or_beginning]|Calculates the present value of an annuity investment with constant payments and interest rate.
    RATE|number_of_periods, payment_per_period, present_value, [future_value], [end_or_beginning], [rate_guess]|Calculates the interest rate of an annuity investment with constant payments.
    # Array
    ARRAYFORMULA|array_formula|Evaluates a formula over arrays, so non-array functions work with ranges.
    FILTER|range, condition1, [condition2, ...]|Returns the rows or columns of a range that meet the specified conditions.
    QUERY|data, query, [headers]|Runs a SQL-like query across data.
    SEQUENCE|rows, [columns], [start], [step]|Returns an array of sequential numbers, such as 1, 2, 3, 4.
    SORT|range, [sort_column, is_ascending, ...]|Sorts the rows of an array or range by the values in one or more columns.
    TRANSPOSE|array_or_range|Transposes the rows and columns of an array or range.
    UNIQUE|range, [by_column], [exactly_once]|Returns the unique rows of a range, in the order in which they first appear.
    BYCOL|array_or_range, LAMBDA|Groups an array by columns by application of a LAMBDA function to each column.
    BYROW|array_or_range, LAMBDA|Groups an array by rows by application of a LAMBDA function to each row.
    MAKEARRAY|rows, columns, LAMBDA|Returns an array of specified dimensions with values calculated by application of a LAMBDA function.
    MAP|array1, [array2, ...], LAMBDA|Maps each value in the given arrays to a new value by application of a LAMBDA function to each value.
    REDUCE|initial_value, array_or_range, LAMBDA|Reduces an array to an accumulated result by application of a LAMBDA function to each value.
    SCAN|initial_value, array_or_range, LAMBDA|Scans an array and produces intermediate values by application of a LAMBDA function to each value.
    SORTN|range, [n], [display_ties_mode], [sort_column1, is_ascending1, ...]|Returns the first n items in a data set after performing a sort.
    # Web
    HYPERLINK|url, [link_label]|Creates a hyperlink inside a cell.
    # Chart
    SPARKLINE|data, [options]|Creates a miniature chart contained within a single cell.
    """
}
