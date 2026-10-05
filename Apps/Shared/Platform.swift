import PlayerCore
import SwiftUI

#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage

extension Image {
    init(platformImage: PlatformImage) { self.init(uiImage: platformImage) }
}

/// Opens a URL in another app (a streaming service, the YouTube app, Safari).
@MainActor
func openExternal(_ url: URL) async -> Bool { await UIApplication.shared.open(url) }
#else
import AppKit
typealias PlatformImage = NSImage

extension NSImage {
    func pngData() -> Data? {
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

extension Image {
    init(platformImage: PlatformImage) { self.init(nsImage: platformImage) }
}

@MainActor
func openExternal(_ url: URL) async -> Bool { NSWorkspace.shared.open(url) }
#endif

extension View {
    /// Text fields for URLs, codes and keys: no capitalisation on iPhone and Apple TV. A no-op on the Mac.
    @ViewBuilder func neverCapitalize() -> some View {
        #if os(macOS)
        self
        #else
        textInputAutocapitalization(.never)
        #endif
    }
}
