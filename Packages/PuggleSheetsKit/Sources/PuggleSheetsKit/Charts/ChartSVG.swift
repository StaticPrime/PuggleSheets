import CoreGraphics
import Foundation

extension ChartScene {
    /// The scene as a standalone SVG document.
    func svgDocument() -> String {
        let width = Self.number(Double(size.width)), height = Self.number(Double(size.height))
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        out += "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(width)\" height=\"\(height)\" viewBox=\"0 0 \(width) \(height)\">\n"
        out += "<rect x=\"0\" y=\"0\" width=\"\(width)\" height=\"\(height)\"\(Self.paint("fill", background))/>\n"
        let family = Self.escaped(svgFontFamily)
        var clipNumber = 0
        var openGroups = 0
        for item in items {
            switch item {
            case .fill(let path, let color):
                out += "<path d=\"\(Self.pathData(path))\"\(Self.paint("fill", color))/>\n"
            case .stroke(let path, let color, let width):
                out += "<path d=\"\(Self.pathData(path))\" fill=\"none\"\(Self.paint("stroke", color)) stroke-width=\"\(Self.number(width))\""
                out += " stroke-linejoin=\"round\" stroke-linecap=\"round\"/>\n"
            case .dots(let points, let radius, let color):
                out += "<g\(Self.paint("fill", color))>"
                let r = Self.number(radius)
                for point in points {
                    out += "<circle cx=\"\(Self.number(Double(point.x)))\" cy=\"\(Self.number(Double(point.y)))\" r=\"\(r)\"/>"
                }
                out += "</g>\n"
            case .text(let text):
                out += "<text x=\"\(Self.number(text.x))\" y=\"\(Self.number(text.y))\" font-family=\"\(family)\""
                out += " font-size=\"\(Self.number(text.font.size))\""
                if text.font.bold { out += " font-weight=\"bold\"" }
                switch text.anchor {
                case .start: break
                case .middle: out += " text-anchor=\"middle\""
                case .end: out += " text-anchor=\"end\""
                }
                if text.angle != 0 {
                    out += " transform=\"rotate(\(Self.number(text.angle)) \(Self.number(text.x)) \(Self.number(text.y)))\""
                }
                out += "\(Self.paint("fill", text.color))>\(Self.escaped(text.string))</text>\n"
            case .clip(let rect):
                clipNumber += 1
                out += "<clipPath id=\"clip\(clipNumber)\"><rect x=\"\(Self.number(Double(rect.minX)))\" y=\"\(Self.number(Double(rect.minY)))\""
                out += " width=\"\(Self.number(Double(rect.width)))\" height=\"\(Self.number(Double(rect.height)))\"/></clipPath>\n"
                out += "<g clip-path=\"url(#clip\(clipNumber))\">\n"
                openGroups += 1
            case .endClip:
                if openGroups > 0 {
                    out += "</g>\n"
                    openGroups -= 1
                }
            }
        }
        while openGroups > 0 {
            out += "</g>\n"
            openGroups -= 1
        }
        out += "</svg>\n"
        return out
    }

    static func paint(_ attribute: String, _ color: ChartColor) -> String {
        var result = " \(attribute)=\"\(color.hex)\""
        if color.alpha < 1 { result += " \(attribute)-opacity=\"\(number(color.alpha))\"" }
        return result
    }

    /// Path commands with coordinates rounded to hundredths.
    static func pathData(_ path: CGPath) -> String {
        var data = ""
        path.applyWithBlock { pointer in
            let element = pointer.pointee
            switch element.type {
            case .moveToPoint:
                data += "M" + point(element.points[0])
            case .addLineToPoint:
                data += "L" + point(element.points[0])
            case .addQuadCurveToPoint:
                data += "Q" + point(element.points[0]) + " " + point(element.points[1])
            case .addCurveToPoint:
                data += "C" + point(element.points[0]) + " " + point(element.points[1]) + " " + point(element.points[2])
            case .closeSubpath:
                data += "Z"
            @unknown default:
                break
            }
        }
        return data
    }

    static func point(_ point: CGPoint) -> String {
        number(Double(point.x)) + " " + number(Double(point.y))
    }

    /// A coordinate with at most two decimals: "12", "12.5", "-0.25".
    static func number(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        let hundredths = (value * 100).rounded()
        if hundredths == 0 { return "0" }
        guard abs(hundredths) < 9e15 else { return String(format: "%.0f", value) }
        let whole = Int(hundredths) / 100
        let fraction = abs(Int(hundredths) % 100)
        let sign = hundredths < 0 && whole == 0 ? "-" : ""
        if fraction == 0 { return sign + String(whole) }
        let decimals = fraction % 10 == 0 ? String(fraction / 10) : (fraction < 10 ? "0" : "") + String(fraction)
        return sign + String(whole) + "." + decimals
    }

    /// Text safe inside XML text and double-quoted attributes: markup characters escaped, control
    /// characters (invalid in XML) dropped.
    static func escaped(_ text: String) -> String {
        guard text.utf8.contains(where: { $0 < 0x20 || $0 == 0x26 || $0 == 0x3C || $0 == 0x3E || $0 == 0x22 }) else { return text }
        var result = ""
        result.reserveCapacity(text.utf8.count + 16)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "\t": result += " "
            default:
                if scalar.value >= 0x20 { result.unicodeScalars.append(scalar) }
            }
        }
        return result
    }
}
