import Testing
import Foundation
@testable import HermesNative

// MARK: - MediaAttachment Tests

@Suite("MediaAttachment")
struct MediaAttachmentTests {

    @Test("MediaAttachment.Category detects image extensions")
    func categoryImageExtensions() {
        let imageExts = ["png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "tiff", "heic", "heif"]
        for ext in imageExts {
            let cat = MediaAttachment.Category(ext: ext)
            #expect(cat == .image, "Expected .image for ext '\(ext)', got \(cat)")
        }
    }

    @Test("MediaAttachment.Category maps unknown extensions to document")
    func categoryDocumentExtensions() {
        let docExts = ["pdf", "txt", "doc", "zip", "mp4", "mp3", "json", ""]
        for ext in docExts {
            let cat = MediaAttachment.Category(ext: ext)
            #expect(cat == .document, "Expected .document for ext '\(ext)', got \(cat)")
        }
    }

    @Test("MediaAttachment.Category is case-insensitive")
    func categoryCaseInsensitive() {
        #expect(MediaAttachment.Category(ext: "PNG") == .image)
        #expect(MediaAttachment.Category(ext: "Jpg") == .image)
        #expect(MediaAttachment.Category(ext: "PDF") == .document)
    }

    @Test("MediaAttachment initializes with path and extracts filename/extension")
    func initFromPath() {
        let attachment = MediaAttachment(path: "/tmp/test-photo.png")
        #expect(attachment.fileName == "test-photo.png")
        #expect(attachment.fileExtension == "png")
        #expect(attachment.category == .image)
        #expect(attachment.thumbnailData == nil)
    }

    @Test("MediaAttachment equality is by ID")
    func equalityByID() {
        let a = MediaAttachment(path: "/tmp/a.png")
        let b = MediaAttachment(path: "/tmp/a.png")
        // Same path, different UUIDs → not equal
        #expect(a != b)

        let c = a
        #expect(a == c)
    }

    @Test("MediaAttachment icon matches category")
    func iconMatchesCategory() {
        #expect(MediaAttachment.Category.image.icon == "photo")
        #expect(MediaAttachment.Category.document.icon == "doc")
    }
}

// MARK: - ChatViewModel Attachment Tests

@Suite("ChatViewModel Attachments")
struct ChatViewModelAttachmentTests {

    @Test("pendingAttachments starts empty")
    @MainActor
    func pendingAttachmentsStartsEmpty() async {
        let vm = ChatViewModel()
        #expect(vm.pendingAttachments.isEmpty)
    }

    @Test("addAttachment appends to pendingAttachments")
    @MainActor
    func addAttachment() async {
        let vm = ChatViewModel()
        // Create a temp file so the thumbnail generation can at least try
        let tmpDir = NSTemporaryDirectory()
        let tmpPath = tmpDir + "test_\(UUID().uuidString).png"
        // Write a minimal 1x1 PNG
        let minimalPNG = Data([
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A // PNG signature
        ])
        try? minimalPNG.write(to: URL(fileURLWithPath: tmpPath))
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }

        vm.addAttachment(path: tmpPath)
        #expect(vm.pendingAttachments.count == 1)
        #expect(vm.pendingAttachments.first?.fileName.hasSuffix(".png") == true)
    }

    @Test("removeAttachment removes the specific attachment")
    @MainActor
    func removeAttachment() async {
        let vm = ChatViewModel()
        let tmpDir = NSTemporaryDirectory()
        let path1 = tmpDir + "test_remove_1_\(UUID().uuidString).png"
        let path2 = tmpDir + "test_remove_2_\(UUID().uuidString).png"
        try? Data([0x89, 0x50, 0x4E, 0x47]).write(to: URL(fileURLWithPath: path1))
        try? Data([0x89, 0x50, 0x4E, 0x47]).write(to: URL(fileURLWithPath: path2))
        defer {
            try? FileManager.default.removeItem(atPath: path1)
            try? FileManager.default.removeItem(atPath: path2)
        }

        vm.addAttachment(path: path1)
        vm.addAttachment(path: path2)
        #expect(vm.pendingAttachments.count == 2)

        let toRemove = vm.pendingAttachments.first!
        vm.removeAttachment(toRemove)
        #expect(vm.pendingAttachments.count == 1)
        #expect(vm.pendingAttachments.first?.id != toRemove.id)
    }

    @Test("clearAttachments removes all pending attachments")
    @MainActor
    func clearAttachments() async {
        let vm = ChatViewModel()
        let tmpDir = NSTemporaryDirectory()
        let path = tmpDir + "test_clear_\(UUID().uuidString).png"
        try? Data([0x89, 0x50, 0x4E, 0x47]).write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }

        vm.addAttachment(path: path)
        vm.addAttachment(path: path)
        #expect(vm.pendingAttachments.count == 2)

        vm.clearAttachments()
        #expect(vm.pendingAttachments.isEmpty)
    }

    @Test("addAttachment accepts non-image files (PDF, text, etc.)")
    @MainActor
    func addDocumentAttachment() async {
        let vm = ChatViewModel()
        let tmpDir = NSTemporaryDirectory()

        let pdfPath = tmpDir + "report_\(UUID().uuidString).pdf"
        try? Data("%PDF-1.4".utf8).write(to: URL(fileURLWithPath: pdfPath))
        defer { try? FileManager.default.removeItem(atPath: pdfPath) }

        vm.addAttachment(path: pdfPath)
        #expect(vm.pendingAttachments.count == 1)
        #expect(vm.pendingAttachments.first?.category == .document)
        #expect(vm.pendingAttachments.first?.fileName.hasSuffix(".pdf") == true)
    }

    @Test("addAttachment handles mixed image and document types")
    @MainActor
    func addMixedAttachments() async {
        let vm = ChatViewModel()
        let tmpDir = NSTemporaryDirectory()

        let imgPath = tmpDir + "photo_\(UUID().uuidString).png"
        let txtPath = tmpDir + "notes_\(UUID().uuidString).txt"
        let csvPath = tmpDir + "data_\(UUID().uuidString).csv"
        try? Data([0x89, 0x50, 0x4E, 0x47]).write(to: URL(fileURLWithPath: imgPath))
        try? Data("hello world".utf8).write(to: URL(fileURLWithPath: txtPath))
        try? Data("a,b,c".utf8).write(to: URL(fileURLWithPath: csvPath))
        defer {
            try? FileManager.default.removeItem(atPath: imgPath)
            try? FileManager.default.removeItem(atPath: txtPath)
            try? FileManager.default.removeItem(atPath: csvPath)
        }

        vm.addAttachment(path: imgPath)
        vm.addAttachment(path: txtPath)
        vm.addAttachment(path: csvPath)
        #expect(vm.pendingAttachments.count == 3)

        let categories = vm.pendingAttachments.map(\.category)
        #expect(categories.contains(.image))
        #expect(categories.filter { $0 == .document }.count == 2)
    }
}

// MARK: - HermesCapabilities Image Detection Tests

@Suite("HermesCapabilities Image Detection")
struct HermesCapabilitiesImageTests {

    @Test("conservative defaults disable image features")
    func conservativeDefaults() {
        let caps = HermesCapabilities.conservativeDefaults
        #expect(!caps.hasImageInput)
        #expect(!caps.hasACPImagePrompts)
        #expect(!caps.supportsImagePrompts)
    }

    @Test("fallback disables image features")
    func fallbackDisablesImage() {
        let caps = HermesCapabilities.fallback(reason: "no gateway")
        #expect(!caps.hasImageInput)
        #expect(!caps.hasACPImagePrompts)
        #expect(caps.source == .fallback(reason: "no gateway"))
    }

    @Test("detects has_image_input boolean")
    func detectsHasImageInput() {
        let payload: AnyCodable = .dictionary([
            "has_image_input": .bool(true),
        ])
        let caps = HermesCapabilities.from(value: payload, method: "gateway.capabilities")
        #expect(caps.hasImageInput)
        #expect(!caps.hasACPImagePrompts)
        #expect(caps.supportsImagePrompts)
    }

    @Test("detects hasImageInput camelCase")
    func detectsCamelCase() {
        let payload: AnyCodable = .dictionary([
            "hasImageInput": .bool(true),
        ])
        let caps = HermesCapabilities.from(value: payload, method: "gateway.capabilities")
        #expect(caps.hasImageInput)
    }

    @Test("detects image_input string truthy")
    func detectsStringTruthy() {
        let payload: AnyCodable = .dictionary([
            "image_input": .string("true"),
        ])
        let caps = HermesCapabilities.from(value: payload, method: "gateway.capabilities")
        #expect(caps.hasImageInput)
    }

    @Test("detects image capability from name fragments")
    func detectsFromNameFragments() {
        let payload: AnyCodable = .dictionary([
            "capabilities": .dictionary([
                "features": .array([
                    .string("multimodal"),
                    .string("tools"),
                ]),
            ]),
        ])
        let caps = HermesCapabilities.from(value: payload, method: "gateway.capabilities")
        #expect(caps.hasImageInput)
    }

    @Test("detects ACP image prompts from name fragments")
    func detectsACPFromNameFragments() {
        let payload: AnyCodable = .dictionary([
            "capabilities": .dictionary([
                "features": .array([
                    .string("acp.image.prompts"),
                ]),
            ]),
        ])
        let caps = HermesCapabilities.from(value: payload, method: "gateway.capabilities")
        #expect(caps.hasACPImagePrompts)
        #expect(caps.supportsImagePrompts)
    }

    @Test("supportsImagePrompts is true when either flag is set")
    func supportsImagePromptsOrLogic() {
        let imageOnly = HermesCapabilities(
            gatewayVersion: nil, hermesVersion: nil,
            capabilityNames: [], hasImageInput: true, hasACPImagePrompts: false,
            source: .gateway(method: "test")
        )
        #expect(imageOnly.supportsImagePrompts)

        let acpOnly = HermesCapabilities(
            gatewayVersion: nil, hermesVersion: nil,
            capabilityNames: [], hasImageInput: false, hasACPImagePrompts: true,
            source: .gateway(method: "test")
        )
        #expect(acpOnly.supportsImagePrompts)

        let neither = HermesCapabilities(
            gatewayVersion: nil, hermesVersion: nil,
            capabilityNames: [], hasImageInput: false, hasACPImagePrompts: false,
            source: .gateway(method: "test")
        )
        #expect(!neither.supportsImagePrompts)
    }

    @Test("version-only response still disables image features")
    func versionOnlyDisablesImage() {
        let payload: AnyCodable = .string("1.2.3")
        let caps = HermesCapabilities.from(value: payload, method: "gateway.version")
        #expect(!caps.hasImageInput)
        #expect(!caps.hasACPImagePrompts)
        #expect(caps.gatewayVersion == "1.2.3")
    }

    @Test("nil result falls back to conservative defaults")
    func nilResultFallback() {
        let caps = HermesCapabilities.from(result: nil, method: "gateway.capabilities")
        #expect(!caps.hasImageInput)
        #expect(!caps.hasACPImagePrompts)
        #expect(caps.source == .gateway(method: "gateway.capabilities"))
    }

    @Test("detects vision capability name")
    func detectsVisionName() {
        let payload: AnyCodable = .dictionary([
            "capabilities": .dictionary([
                "features": .array([
                    .string("vision"),
                ]),
            ]),
        ])
        let caps = HermesCapabilities.from(value: payload, method: "gateway.capabilities")
        #expect(caps.hasImageInput)
    }

    @Test("detects supports_images boolean")
    func detectsSupportsImages() {
        let payload: AnyCodable = .dictionary([
            "supports_images": .bool(true),
        ])
        let caps = HermesCapabilities.from(value: payload, method: "gateway.capabilities")
        #expect(caps.hasImageInput)
    }

    @Test("detects image-input capability name with hyphens")
    func detectsHyphenatedImageInput() {
        let payload: AnyCodable = .dictionary([
            "capabilities": .dictionary([
                "features": .array([
                    .string("image-input"),
                ]),
            ]),
        ])
        let caps = HermesCapabilities.from(value: payload, method: "gateway.capabilities")
        #expect(caps.hasImageInput)
    }
}

// MARK: - HermesCapabilitiesStore Tests

@Suite("HermesCapabilitiesStore")
struct HermesCapabilitiesStoreTests {

    @Test("store starts with conservative defaults")
    @MainActor
    func startsWithConservativeDefaults() async {
        let store = HermesCapabilitiesStore()
        #expect(!store.hasImageInput)
        #expect(!store.hasACPImagePrompts)
        #expect(store.capabilities == HermesCapabilities.conservativeDefaults)
    }

    @Test("reset falls back to no-image defaults")
    @MainActor
    func resetFallsBack() async {
        let store = HermesCapabilitiesStore()
        // After a gateway reports image support, reset should clear it
        // Since capabilities setter is private, we verify via reset
        store.reset(reason: "disconnected")
        #expect(!store.hasImageInput)
        #expect(!store.hasACPImagePrompts)
        #expect(store.capabilities.source == .fallback(reason: "disconnected"))
    }
}

// MARK: - ChatMessage Attachment Parsing Tests

@Suite("ChatMessage Attachment Parsing")
struct ChatMessageAttachmentParsingTests {

    @Test("MediaParser extracts MEDIA: lines for existing files")
    func mediaParserExtracts() {
        // Create a real temp file so the file-existence check passes
        let tmpDir = NSTemporaryDirectory()
        let tmpPath = tmpDir + "media_test_\(UUID().uuidString).png"
        let data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        try? data.write(to: URL(fileURLWithPath: tmpPath))
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }

        let content = "Here's the result:\nMEDIA:\(tmpPath)\nAnd some more text"
        let attachments = MediaParser.extractAttachments(from: content)
        #expect(attachments.count == 1)
        #expect(attachments.first?.fileName == URL(fileURLWithPath: tmpPath).lastPathComponent)
    }

    @Test("MediaParser extracts multiple MEDIA: lines")
    func mediaParserMultipleAttachments() {
        let tmpDir = NSTemporaryDirectory()
        let path1 = tmpDir + "media_multi_1_\(UUID().uuidString).png"
        let path2 = tmpDir + "media_multi_2_\(UUID().uuidString).csv"
        try? Data([0x89, 0x50]).write(to: URL(fileURLWithPath: path1))
        try? Data([0x30, 0x31]).write(to: URL(fileURLWithPath: path2))
        defer {
            try? FileManager.default.removeItem(atPath: path1)
            try? FileManager.default.removeItem(atPath: path2)
        }

        let content = "```\nMEDIA:\(path1)\nMEDIA:\(path2)\n```"
        let attachments = MediaParser.extractAttachments(from: content)
        #expect(attachments.count == 2)
    }

    @Test("MediaParser skips MEDIA: lines for non-existent files")
    func mediaParserSkipsNonExistent() {
        let content = "MEDIA:/nonexistent/path/image.png"
        let attachments = MediaParser.extractAttachments(from: content)
        #expect(attachments.isEmpty)
    }

    @Test("contentWithoutAttachments strips MEDIA: lines")
    func contentWithoutAttachments() {
        let content = "Result:\nMEDIA:/tmp/image.png\nDone"
        let msg = ChatMessage(role: .assistant, content: content)
        let stripped = msg.contentWithoutAttachments
        #expect(!stripped.contains("MEDIA:"))
        #expect(stripped.contains("Result:"))
        #expect(stripped.contains("Done"))
    }

    @Test("MEDIA: lines with surrounding backticks parse if file exists")
    func mediaParserWithBackticks() {
        let tmpDir = NSTemporaryDirectory()
        let tmpPath = tmpDir + "media_backtick_\(UUID().uuidString).html"
        try? Data("<html></html>".utf8).write(to: URL(fileURLWithPath: tmpPath))
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }

        // Realistic: MEDIA: line inside a code block (backtick-quoted)
        let content = "```\nMEDIA:\(tmpPath)\n```"
        let attachments = MediaParser.extractAttachments(from: content)
        #expect(attachments.count == 1)
    }
}