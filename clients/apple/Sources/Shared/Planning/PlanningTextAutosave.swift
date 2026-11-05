import Foundation
import Observation

struct PlanningTextValue: Codable, Equatable {
  var title: String
  var body: String
}

/// Serial writes with a retained local draft: navigation and a failed request
/// must not discard edits or allow an older request to overwrite newer text.
@MainActor @Observable
final class PlanningTextAutosave {
  var title: String { didSet { changed() } }
  var body: String { didSet { changed() } }
  private(set) var error: String?
  private(set) var isSaving = false
  private var saved: PlanningTextValue
  private var applying = false
  private var debounce: Task<Void, Never>?
  private let titleLimit: Int
  private let bodyLimit: Int
  private let key: String
  private let defaults: UserDefaults?
  private let write: (PlanningTextValue, PlanningTextValue) async throws -> Void
  private struct Draft: Codable { let value: PlanningTextValue; let saved: PlanningTextValue }

  init(value: PlanningTextValue, titleLimit: Int, bodyLimit: Int, key: String,
       defaults: UserDefaults? = .standard,
       write: @escaping (PlanningTextValue, PlanningTextValue) async throws -> Void) {
    self.titleLimit = titleLimit
    self.bodyLimit = bodyLimit
    self.key = key
    self.defaults = defaults
    self.write = write
    let draft = defaults?.data(forKey: key).flatMap { try? JSONDecoder().decode(Draft.self, from: $0) }
    title = draft?.value.title ?? value.title
    body = draft?.value.body ?? value.body
    saved = draft?.saved ?? value
  }

  var value: PlanningTextValue { .init(title: title, body: body) }
  var hasChanges: Bool { value != saved }

  private func changed() {
    guard !applying else { return }
    persist()
    debounce?.cancel()
    debounce = Task { [self] in
      do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
      // Keep the request independent of the cancellable typing debounce.
      flush()
    }
  }

  func flush() {
    debounce?.cancel()
    debounce = nil
    Task { await savePending() }
  }

  func receive(_ remote: PlanningTextValue) {
    guard !hasChanges, !isSaving else { return }
    applying = true
    saved = remote
    title = remote.title
    body = remote.body
    applying = false
  }

  func savePending() async {
    guard !isSaving else { return }
    isSaving = true
    defer { isSaving = false }
    while hasChanges {
      let next = value
      guard !next.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        error = "Add a title to save."
        return
      }
      guard next.title.count <= titleLimit, next.body.count <= bodyLimit else {
        error = "Title: up to \(titleLimit) characters. Description: up to \(bodyLimit)."
        return
      }
      do {
        try await write(next, saved)
        saved = next
        error = nil
        persist()
      } catch {
        self.error = "Couldn’t save. Your draft is kept on this device."
        return
      }
    }
  }

  private func persist() {
    if hasChanges, let data = try? JSONEncoder().encode(Draft(value: value, saved: saved)) {
      defaults?.set(data, forKey: key)
    } else {
      defaults?.removeObject(forKey: key)
    }
  }
}

@MainActor
final class PlanningTextEditors {
  private var editors: [String: PlanningTextAutosave] = [:]

  func editor(scope: [String], value: PlanningTextValue, titleLimit: Int, bodyLimit: Int,
              write: @escaping (PlanningTextValue, PlanningTextValue) async throws -> Void) -> PlanningTextAutosave {
    let key = "hq-planning-draft-v1." + ((try? JSONEncoder().encode(scope))?.base64EncodedString() ?? "")
    if let editor = editors[key] { return editor }
    let editor = PlanningTextAutosave(value: value, titleLimit: titleLimit, bodyLimit: bodyLimit, key: key, write: write)
    editors[key] = editor
    return editor
  }
}
