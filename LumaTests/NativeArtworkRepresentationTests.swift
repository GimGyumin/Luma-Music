#if os(iOS) && !targetEnvironment(macCatalyst)
import CoreImage
import MediaPlayer
import Testing
import UIKit
@testable import Luma

@Suite("Native player artwork representations") @MainActor
struct NativeArtworkRepresentationTests {
    @Test func coreImageBackedArtworkHasANativeRepresentation() throws {
        if #available(iOS 27.0, *) {
            let source = CIImage(color: CIColor(red: 0.3, green: 0.5, blue: 0.8))
                .cropped(to: CGRect(x: 0, y: 0, width: 24, height: 24))
            let image = UIImage(ciImage: source)
            #expect(image.cgImage == nil)
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            let native = try #require(LumaNativeMediaSession.artworkCGImage(artwork, requestedSize: .zero))
            #expect(native.width == 24 && native.height == 24)
        }
    }
}
#endif
