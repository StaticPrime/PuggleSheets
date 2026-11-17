import AppKit
import PuggleSheetsKit
import UniformTypeIdentifiers

/// Dropping image files (or pictures from other apps) on the grid places them over the cells.
extension GridView {
    private func droppedImage(_ pasteboard: NSPasteboard) -> ImageData? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            for url in urls where UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false {
                if let data = try? Data(contentsOf: url), let image = SpreadsheetController.imageData(from: data) { return image }
            }
        }
        if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            return SpreadsheetController.imageData(from: data)
        }
        return nil
    }

    private func acceptsDrop(_ pasteboard: NSPasteboard) -> Bool {
        if pasteboard.types?.contains(.png) == true || pasteboard.types?.contains(.tiff) == true { return true }
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.contains { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) ?? false }
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        acceptsDrop(sender.draggingPasteboard) ? .copy : []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        acceptsDrop(sender.draggingPasteboard) ? .copy : []
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let image = droppedImage(sender.draggingPasteboard) else { return false }
        let point = convert(sender.draggingLocation, from: nil)
        if editor != nil { commitEditing() }
        controller.insertImageOverCells(image, at: clampedAddress(at: point))
        window?.makeFirstResponder(self)
        return true
    }
}
