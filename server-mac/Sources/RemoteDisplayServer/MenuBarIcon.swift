import AppKit

enum MenuBarIcon {
    /// The icon `symbol` with a small badge beside it per symbol in `badges`, as one
    /// template image: a MenuBarExtra label shows only its first Image, so an HStack of
    /// images loses the badges. The icon is drawn as `Image(systemName:)` shows it.
    static func badged(_ symbol: String, _ badges: [String]) -> NSImage {
        let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage()
        let small = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        let parts = [icon] + badges.compactMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil)?.withSymbolConfiguration(small)
        }
        let gap: CGFloat = 1
        let width = parts.reduce(-gap) { $0 + gap + $1.size.width }
        let height = parts.reduce(0) { max($0, $1.size.height) }
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            var x: CGFloat = 0
            for part in parts {
                part.draw(in: NSRect(x: x, y: (height - part.size.height) / 2,
                                     width: part.size.width, height: part.size.height))
                x += part.size.width + gap
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = parts.compactMap(\.accessibilityDescription).joined(separator: ", ")
        return image
    }
}
