import Foundation
import Testing
@testable import LibFx

@Test func promptValidationRecognizesSupportedImageHeaders() throws {
    let configuration = FxConfiguration(apiKey: "", model: "test/model")
    let headers: [(FxImageFormat, Data)] = [
        (.png, Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])),
        (.jpeg, Data([0xff, 0xd8, 0xff])),
        (.gif, Data("GIF89a".utf8)),
        (.webp, Data("RIFF0000WEBP".utf8)),
    ]
    for (format, bytes) in headers {
        try configuration.validatePrompt([.image(FxImage(data: bytes, format: format))])
        let other: FxImageFormat = format == .png ? .jpeg : .png
        #expect(throws: FxError.self) {
            try configuration.validatePrompt([.image(FxImage(data: bytes, format: other))])
        }
    }
    #expect(throws: FxError.self) {
        try configuration.validatePrompt([.image(FxImage(data: Data("invalid".utf8), format: .png))])
    }
}

@Test func promptValidationDefersImageBytesButNeverRunsPreparation() throws {
    var configuration = FxConfiguration(apiKey: "", model: "test/model")
    configuration.prepareImage = { image in
        Issue.record("Validation ran asynchronous image preparation")
        return image
    }
    let image = FxPromptContent.image(FxImage(data: Data(repeating: 0, count: 4 * 1024 * 1024), format: .png))
    try configuration.validatePrompt([image])
    #expect(throws: FxError.self) { try configuration.validatePrompt(Array(repeating: image, count: 9)) }
    #expect(throws: FxError.self) {
        try configuration.validatePrompt([.text(String(repeating: "中", count: 3 * 1024 * 1024))])
    }
}

@Test(arguments: [3145728, 3670016, 4194304])
func referencedImageFallbackKeepsReferencesAndDropsOversizedAttachments(size: Int) throws {
    var bytes = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
    bytes.append(Data(repeating: 0, count: size - bytes.count))
    let content = ["first", "second"].map {
        FxPromptContent.image(FxImage(data: bytes, format: .png, sourceReference: $0))
    }
    let prepared = try PreparedPrompt(content)
    #expect(prepared.images.isEmpty)
    #expect(prepared.blocks.map { $0["sourceRef"]?.string } == ["first", "second"])
    #expect(prepared.blocks.allSatisfy { $0["_meta"] == nil })
    #expect(throws: FxError.self) {
        try PreparedPrompt(content.map { _ in .image(FxImage(data: bytes, format: .png)) })
    }
}
