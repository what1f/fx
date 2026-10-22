import CryptoKit
import Foundation

/// Admission rules shared by built-in and host-provided session stores.
public enum FxSessionStorageValidation {
  public static func validateInput(
    sessionID: String, inputID: String, content: [FxPromptContent], options: FxSessionOptions,
    steering: Bool = false, deferringImageLimits: Bool = false
  ) throws {
    guard validSessionIdentifier(sessionID), validSessionIdentifier(inputID) else {
      throw FxError.invalidInput("Invalid session or message ID")
    }
    try validateSessionInput(content, deferringImageLimits: deferringImageLimits)
    try SessionInputAdmission.validate(content, options: options)
    if steering, content.allSatisfy({ if case .text = $0 { true } else { false } }) {
      let text = content.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined(
        separator: "\n")
      guard text.utf8.count <= 64 * 1024 else {
        throw FxError.invalidInput("Steering text exceeds the size limit")
      }
    }
  }
  public static func validateMarks(_ marks: [FxSessionJournalMark]) throws {
    for mark in marks {
      if case .completed(let id) = mark, !validInputID(id) {
        throw FxPersistenceError.invalidJournal
      }
    }
  }
  public static func imageName(for data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
