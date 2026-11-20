import Foundation

/// Where an object floating over the grid sits: the cell its top-left corner is in, how far into that
/// cell, and its size, all in pixels at 100% zoom.
public struct ObjectAnchor: Hashable, Sendable, Codable {
    public var cell: CellAddress
    public var offsetX: Double
    public var offsetY: Double
    public var width: Double
    public var height: Double

    public init(cell: CellAddress, offsetX: Double = 0, offsetY: Double = 0, width: Double, height: Double) {
        self.cell = cell
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.width = width
        self.height = height
    }
}

/// An image file's bytes, format and size in pixels. Other formats are converted to PNG before they
/// get here.
public struct ImageData: Hashable, Sendable, Codable {
    public enum Format: String, CaseIterable, Sendable, Codable {
        case png, jpeg, gif

        public var fileExtension: String {
            switch self {
            case .png: "png"
            case .jpeg: "jpeg"
            case .gif: "gif"
            }
        }

        public var mimeType: String {
            switch self {
            case .png: "image/png"
            case .jpeg: "image/jpeg"
            case .gif: "image/gif"
            }
        }
    }

    public var data: Data
    public var format: Format
    public var pixelWidth: Int
    public var pixelHeight: Int

    public init(data: Data, format: Format, pixelWidth: Int, pixelHeight: Int) {
        self.data = data
        self.format = format
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    /// Reads the format and size from a PNG, JPEG or GIF file's header; nil for anything else.
    public init?(data: Data) {
        let bytes = [UInt8](data.prefix(64 * 1024))
        func bigEndian(_ offset: Int, _ count: Int) -> Int? {
            guard offset + count <= bytes.count else { return nil }
            return bytes[offset..<(offset + count)].reduce(0) { $0 << 8 | Int($1) }
        }
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
           let width = bigEndian(16, 4), let height = bigEndian(20, 4), width > 0, height > 0 {
            self.init(data: data, format: .png, pixelWidth: width, pixelHeight: height)
            return
        }
        if bytes.count >= 10, bytes.starts(with: Array("GIF8".utf8)) {
            let width = Int(bytes[6]) | Int(bytes[7]) << 8, height = Int(bytes[8]) | Int(bytes[9]) << 8
            guard width > 0, height > 0 else { return nil }
            self.init(data: data, format: .gif, pixelWidth: width, pixelHeight: height)
            return
        }
        if bytes.starts(with: [0xFF, 0xD8]) {
            // Walk the segments to the start-of-frame marker, which holds the size.
            var offset = 2
            while offset + 9 < bytes.count {
                guard bytes[offset] == 0xFF else { return nil }
                let marker = bytes[offset + 1]
                if marker == 0xFF { offset += 1; continue }
                if marker == 0xD8 || marker == 0x01 || (0xD0...0xD7).contains(marker) { offset += 2; continue }
                guard let length = bigEndian(offset + 2, 2), length >= 2 else { return nil }
                if (0xC0...0xCF).contains(marker), marker != 0xC4, marker != 0xC8, marker != 0xCC {
                    guard let height = bigEndian(offset + 5, 2), let width = bigEndian(offset + 7, 2), width > 0, height > 0 else { return nil }
                    self.init(data: data, format: .jpeg, pixelWidth: width, pixelHeight: height)
                    return
                }
                offset += 2 + length
            }
            return nil
        }
        return nil
    }

    /// Hashing every byte of a big image is slow: the size and the first bytes tell images apart well enough.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(format)
        hasher.combine(pixelWidth)
        hasher.combine(pixelHeight)
        hasher.combine(data.count)
        hasher.combine(data.prefix(256))
    }
}

/// An image inside a cell (Insert ▸ Image ▸ Insert image in cell), drawn fitted to the cell.
public struct CellImage: Hashable, Sendable, Codable {
    public var image: ImageData
    /// Alt text.
    public var altText: String

    public init(image: ImageData, altText: String = "") {
        self.image = image
        self.altText = altText
    }
}

/// Something floating over the grid: an image (Insert ▸ Image ▸ Insert image over cells) or a chart.
public struct SheetObject: Identifiable, Hashable, Sendable, Codable {
    public enum Content: Hashable, Sendable, Codable {
        case image(ImageData)
        case chart(ChartSpec)
        case slicer(SlicerSpec)
    }

    public let id: UUID
    public var anchor: ObjectAnchor
    public var content: Content
    /// Alt text: a title and a description.
    public var title: String
    public var altDescription: String

    public init(id: UUID = UUID(), anchor: ObjectAnchor, content: Content, title: String = "", altDescription: String = "") {
        self.id = id
        self.anchor = anchor
        self.content = content
        self.title = title
        self.altDescription = altDescription
    }

    public var chart: ChartSpec? {
        if case .chart(let spec) = content { return spec }
        return nil
    }

    public var image: ImageData? {
        if case .image(let image) = content { return image }
        return nil
    }

    public var slicer: SlicerSpec? {
        if case .slicer(let spec) = content { return spec }
        return nil
    }
}
