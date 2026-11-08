import SwiftUI
import UIKit
import CoreImage

/// Cover laden und zwischenspeichern (Speicher + Platte), offline aus dem Cache
actor ImageLoader {
    static let shared = ImageLoader()

    nonisolated(unsafe) private let memory = NSCache<NSURL, UIImage>()
    private let session: URLSession
    private var running: [URL: Task<UIImage?, Never>] = [:]
    private let dir: URL

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        dir = caches.appending(path: "Artwork", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cfg = URLSessionConfiguration.default
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        session = URLSession(configuration: cfg)
        memory.countLimit = 300
    }

    nonisolated static func cached(_ url: URL) -> UIImage? { shared.memoryPeek(url) }
    nonisolated private func memoryPeek(_ url: URL) -> UIImage? { memory.object(forKey: url as NSURL) }

    private func file(_ url: URL) -> URL {
        dir.appending(path: String(UInt(bitPattern: url.absoluteString.stableHash), radix: 36))
    }

    func image(_ url: URL, maxPixel: CGFloat = 600) async -> UIImage? {
        if let m = memory.object(forKey: url as NSURL) { return m }
        if let t = running[url] { return await t.value }
        let path = file(url)
        let task = Task<UIImage?, Never> {
            if let data = try? Data(contentsOf: path), let img = Self.downsample(data, maxPixel) { return img }
            guard let (data, resp) = try? await session.data(from: url), (resp as? HTTPURLResponse)?.statusCode ?? 200 < 400,
                  let img = Self.downsample(data, maxPixel) else { return nil }
            if let jpg = img.jpegData(compressionQuality: 0.85) { try? jpg.write(to: path) }
            return img
        }
        running[url] = task
        let img = await task.value
        running[url] = nil
        if let img { memory.setObject(img, forKey: url as NSURL) }
        return img
    }

    private static func downsample(_ data: Data, _ maxPixel: CGFloat) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceShouldCacheImmediately: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: maxPixel]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// Mittlere Farbe eines Covers (für Sendungskopf und Player-Hintergrund, Apple: `artworkPrimaryColor`)
    nonisolated static func averageColor(_ image: UIImage) -> UIColor? {
        guard let ci = CIImage(image: image) else { return nil }
        let f = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: ci, kCIInputExtentKey: CIVector(cgRect: ci.extent)])
        guard let out = f?.outputImage else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        CIContext(options: [.workingColorSpace: NSNull()]).render(out, toBitmap: &px, rowBytes: 4,
                                                                   bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        return UIColor(red: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255, alpha: 1)
    }
}

extension String {
    /// Über App-Starts stabiler Hash (Swifts `hashValue` ist pro Start zufällig)
    var stableHash: Int {
        var h: UInt64 = 1469598103934665603
        for b in utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return Int(bitPattern: UInt(h))
    }
}

/// Cover-Ansicht mit Platzhalter (abgerundet wie bei Apple)
struct Artwork: View {
    let url: URL?
    var size: CGFloat? = nil
    var corner: CGFloat = 8
    var title: String = ""
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Placeholder(title: title)
            }
        }
        .frame(width: size, height: size)
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous).strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
        .task(id: url) {
            guard let url else { image = nil; return }
            if let c = ImageLoader.cached(url) { image = c; return }
            image = await ImageLoader.shared.image(url)
        }
        .accessibilityHidden(true)
    }

    /// Farbe des erzeugten Platzhalters (Hintergrund von Karten/Player, wenn es kein Cover gibt)
    static func placeholderColor(_ title: String) -> Color {
        Color(hue: Double(abs(title.stableHash) % 360) / 360, saturation: 0.6, brightness: 0.6)
    }

    /// Erzeugter Platzhalter (auch für Demodaten ohne Cover)
    struct Placeholder: View {
        let title: String
        var body: some View {
            let hue = Double(abs(title.stableHash) % 360) / 360
            LinearGradient(colors: [Color(hue: hue, saturation: 0.55, brightness: 0.85), Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.75, brightness: 0.45)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .overlay {
                    GeometryReader { g in
                        Text(initials)
                            .font(.system(size: g.size.width * 0.32, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white.opacity(0.92))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
        }
        var initials: String {
            let words = title.split(separator: " ").filter { $0.first?.isLetter == true || $0.first?.isNumber == true }
            return String(words.prefix(2).compactMap(\.first)).uppercased()
        }
    }
}
