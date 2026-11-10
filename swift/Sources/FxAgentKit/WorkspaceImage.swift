import Foundation
import ImageIO
import UniformTypeIdentifiers
import LibFx

func workspaceImage(at url: URL) throws -> FxToolResult? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
          CGImageSourceGetType(source) != nil else { return nil }
    try Task.checkCancellation()
    let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: 1568, kCGImageSourceCreateThumbnailWithTransform: true]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
        throw FxError.invalidInput("Image could not be read")
    }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
        throw FxError.invalidInput("Image could not be encoded")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw FxError.invalidInput("Image could not be encoded") }
    return FxToolResult(text: "Image \(image.width) × \(image.height)", images: [FxImage(data: data as Data, format: .png)])
}
