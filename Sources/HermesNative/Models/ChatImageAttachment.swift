import Foundation

/// Encoded image attached to a user chat prompt.
struct ChatImageAttachment: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var fileName: String
    var mimeType: String
    var dataBase64: String
    var thumbnailBase64: String
    var width: Int
    var height: Int

    init(
        id: UUID = UUID(),
        fileName: String,
        mimeType: String = "image/jpeg",
        dataBase64: String,
        thumbnailBase64: String,
        width: Int,
        height: Int
    ) {
        self.id = id
        self.fileName = fileName
        self.mimeType = mimeType
        self.dataBase64 = dataBase64
        self.thumbnailBase64 = thumbnailBase64
        self.width = width
        self.height = height
    }

    var dataURL: String {
        "data:\(mimeType);base64,\(dataBase64)"
    }

    var thumbnailDataURL: String {
        "data:\(mimeType);base64,\(thumbnailBase64)"
    }

    var displayName: String {
        fileName.isEmpty ? "Image" : fileName
    }
}
