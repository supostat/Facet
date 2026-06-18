import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// PNG round-trip for golden snapshots. Both the encode CGImage and the decode
// CGContext use CGColorSpaceCreateDeviceRGB() — an UNTAGGED device space — and
// the exact .bgra8Unorm premultiplied layout (premultipliedFirst |
// byteOrder32Little). With no ICC profile on either side, ImageIO performs no
// colormatch, so bytes written equal bytes read back and the comparison stays
// on premultiplied data that matches the renderer's getBytes output. Test-only:
// any failure is a hard fatalError.
enum PngImage {
    private static let bitsPerComponent = 8
    private static let bytesPerPixel = 4
    private static let bitmapInfo = CGBitmapInfo(
        rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    )

    // Single-channel R8 (deviceGray, alpha .none, no colormatch) — the grayscale
    // analogue of the RGBA round-trip above for the atlas mask dump. The R8 atlas
    // texture is one byte per pixel; an untagged deviceGray space with alpha
    // .none performs no colormatch, so write(bytes) == read(file) byte-for-byte.
    private static let grayBytesPerPixel = 1
    private static let grayBitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)

    static func write(bgraPixels: [UInt8], width: Int, height: Int, url: URL) {
        let expectedCount = width * height * bytesPerPixel
        precondition(
            bgraPixels.count == expectedCount,
            "PngImage.write: expected \(expectedCount) bytes, got \(bgraPixels.count)"
        )

        let image = makeCGImage(bgraPixels: bgraPixels, width: width, height: height)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            fatalError("PngImage.write: could not create a PNG destination at \(url.path)")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            fatalError("PngImage.write: failed to finalize the PNG at \(url.path)")
        }
    }

    static func read(url: URL) -> (bgraPixels: [UInt8], width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            fatalError("PngImage.read: could not open a PNG source at \(url.path)")
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            fatalError("PngImage.read: could not decode the PNG at \(url.path)")
        }

        let width = image.width
        let height = image.height
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)

        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: bitsPerComponent,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo.rawValue
            ) else {
                fatalError("PngImage.read: could not create a decode context for \(url.path)")
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }

        return (bgraPixels: pixels, width: width, height: height)
    }

    static func readGray(url: URL) -> (grayPixels: [UInt8], width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            fatalError("PngImage.readGray: could not open a PNG source at \(url.path)")
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            fatalError("PngImage.readGray: could not decode the PNG at \(url.path)")
        }

        let width = image.width
        let height = image.height
        let bytesPerRow = width * grayBytesPerPixel
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)

        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: bitsPerComponent,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: grayBitmapInfo.rawValue
            ) else {
                fatalError("PngImage.readGray: could not create a decode context for \(url.path)")
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }

        return (grayPixels: pixels, width: width, height: height)
    }

    private static func makeCGImage(bgraPixels: [UInt8], width: Int, height: Int) -> CGImage {
        let bytesPerRow = width * bytesPerPixel
        var pixels = bgraPixels
        guard let context = pixels.withUnsafeMutableBytes({ buffer in
            CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: bitsPerComponent,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo.rawValue
            )
        }) else {
            fatalError("PngImage.write: could not create an encode context (\(width)x\(height))")
        }
        guard let image = context.makeImage() else {
            fatalError("PngImage.write: could not snapshot the encode context to a CGImage")
        }
        return image
    }
}
