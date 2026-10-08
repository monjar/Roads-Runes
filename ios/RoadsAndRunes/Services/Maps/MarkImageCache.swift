import RoadsAndRunesArt
import UIKit

/// Marks rendered once as images for the map: an annotation view is UIKit, and a
/// map with fifty things on it should not draw fifty sigils on every pan.
final class MarkImageCache {
    static let shared = MarkImageCache()
    private let cache = NSCache<NSString, UIImage>()

    func image(_ mark: Mark, size: CGFloat, palette: InkPalette = .phone) -> UIImage? {
        let scale = UIScreen.main.scale
        let key = "\(mark.id)|\(size)|\(scale)|\(palette.paper.red)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let cg = MarkRenderer.cgImage(mark, size: size, scale: scale, palette: palette) else { return nil }
        let image = UIImage(cgImage: cg, scale: scale, orientation: .up)
        cache.setObject(image, forKey: key)
        return image
    }
}
