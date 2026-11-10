import SwiftUI
import UIKit
import Nuke

/// Обход медленного CDN картинок Spotify (INT-007): `i.scdn.co` → зеркало Akamai,
/// при неудаче — исходный адрес. Порт `utils/SpotifyImageCdn.kt`.
enum SpotifyImageCDN {
    static let spotifyHost = "i.scdn.co"
    static let akamaiHost = "image-cdn-ak.spotifycdn.com"

    /// Адреса в порядке попыток.
    static func candidates(_ raw: String?) -> [URL] {
        guard let raw = raw, !raw.isEmpty, let url = URL(string: raw) else { return [] }
        guard url.host == spotifyHost, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return [url] }
        parts.host = akamaiHost
        return [parts.url, url].compactMap { $0 }
    }
}

final class ArtworkLoader: ObservableObject {
    @Published var image: UIImage?

    private var task: ImageTask?
    private var loadedKey: String?

    func load(_ raw: String?, pixelWidth: CGFloat) {
        let key = "\(raw ?? "")|\(Int(pixelWidth))"
        if key == loadedKey { return }
        loadedKey = key
        task?.cancel()
        image = nil
        attempt(SpotifyImageCDN.candidates(raw), pixelWidth: pixelWidth, key: key)
    }

    private func attempt(_ urls: [URL], pixelWidth: CGFloat, key: String) {
        guard let url = urls.first else { return }
        let request = ImageRequest(url: url, processors: [ImageProcessors.Resize(width: pixelWidth, unit: .pixels)])
        task = ImagePipeline.shared.loadImage(with: request) { [weak self] result in
            guard let self = self, self.loadedKey == key else { return }
            switch result {
            case .success(let response):
                self.image = response.image
            case .failure:
                self.attempt(Array(urls.dropFirst()), pixelWidth: pixelWidth, key: key)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        if image == nil { loadedKey = nil }
    }
}

/// Обложка трека, альбома, плейлиста или фото артиста (`AsyncImage` есть только с iOS 15).
struct ArtworkView: View {
    let url: String?
    var size: CGFloat = 48
    var cornerRadius: CGFloat = 6
    var circle = false
    var placeholderSymbol = "music.note"

    @StateObject private var loader = ArtworkLoader()

    var body: some View {
        ZStack {
            Color.secondary.opacity(0.18)
            if let image = loader.image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: placeholderSymbol)
                    .font(.system(size: size * 0.4))
                    .foregroundColor(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: circle ? size / 2 : cornerRadius, style: .continuous))
        .onAppear { loader.load(url, pixelWidth: size * UIScreen.main.scale) }
        .onChange(of: url) { loader.load($0, pixelWidth: size * UIScreen.main.scale) }
        .onDisappear { loader.cancel() }
    }
}
