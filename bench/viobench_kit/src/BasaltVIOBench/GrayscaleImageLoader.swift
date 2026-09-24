import CoreGraphics
import Foundation
import ImageIO

struct GrayscaleImage: Equatable {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let pixels: Data
}

enum GrayscaleImageLoaderError: Error {
    case cannotDecode(URL)
    case invalidDimensions(expectedWidth: Int, expectedHeight: Int, actualWidth: Int, actualHeight: Int)
    case cannotCreateContext
}

enum GrayscaleImageLoader {
    static func load(
        _ url: URL,
        expectedWidth: Int,
        expectedHeight: Int
    ) throws -> GrayscaleImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw GrayscaleImageLoaderError.cannotDecode(url)
        }
        guard image.width == expectedWidth, image.height == expectedHeight else {
            throw GrayscaleImageLoaderError.invalidDimensions(
                expectedWidth: expectedWidth,
                expectedHeight: expectedHeight,
                actualWidth: image.width,
                actualHeight: image.height
            )
        }
        var bytes = Data(count: expectedWidth * expectedHeight)
        let drew = bytes.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: expectedWidth,
                    height: expectedHeight,
                    bitsPerComponent: 8,
                    bytesPerRow: expectedWidth,
                    space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                  ) else {
                return false
            }
            context.interpolationQuality = .none
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: expectedWidth, height: expectedHeight)
            )
            return true
        }
        guard drew else { throw GrayscaleImageLoaderError.cannotCreateContext }
        return GrayscaleImage(
            width: expectedWidth,
            height: expectedHeight,
            bytesPerRow: expectedWidth,
            pixels: bytes
        )
    }
}
