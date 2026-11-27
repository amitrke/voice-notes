import Flutter
import UIKit
import UniformTypeIdentifiers

/// The folder backups go to (lib/services/backup_folder.dart): the app's
/// folder in iCloud Drive ("iCloud Drive › Voice Notes"), or a folder the
/// user picks in Files. When iCloud is signed out, a folder on this iPhone.
final class BackupFolder: NSObject, UIDocumentPickerDelegate {
  static let container = "iCloud.com.subnext.voicenotes"
  private static let bookmarkKey = "backupFolderBookmark"

  private let defaults = UserDefaults.standard
  private let queue = DispatchQueue(label: "com.subnext.voicenotes.backup", qos: .utility)
  private var picking: FlutterResult?

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "device":
      result([
        "name": UIDevice.current.name,
        // Not carried to a new iPhone restored from this one's backup.
        "id": UIDevice.current.identifierForVendor?.uuidString ?? "iphone",
      ])
    case "pick":
      pick(result)
    case "reset":
      defaults.removeObject(forKey: Self.bookmarkKey)
      work(result) { self.location() }
    case "location":
      work(result) { self.location() }
    case "list":
      work(result) { try self.list() }
    case "read":
      guard let name = args["name"] as? String else { return result(Self.badArgs) }
      work(result) { try self.read(name) }
    case "write":
      guard let name = args["name"] as? String, let text = args["text"] as? String
      else { return result(Self.badArgs) }
      work(result) {
        try self.write(name, text)
        return nil
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private static let badArgs = FlutterError(code: "args", message: "missing arguments", details: nil)

  /// iCloud lookups can block, so everything but the picker runs off the main thread.
  private func work(_ result: @escaping FlutterResult, _ body: @escaping () throws -> Any?) {
    queue.async {
      do {
        let v = try body()
        DispatchQueue.main.async { result(v) }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "backup", message: error.localizedDescription, details: nil))
        }
      }
    }
  }

  private enum Kind { case custom, icloud, local }

  private func folder() -> (url: URL, kind: Kind) {
    if let data = defaults.data(forKey: Self.bookmarkKey) {
      var stale = false
      if let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale) {
        if stale, let fresh = scoped(url, { try? url.bookmarkData() }) {
          defaults.set(fresh, forKey: Self.bookmarkKey)
        }
        return (url, .custom)
      }
    }
    let fm = FileManager.default
    if let root = fm.url(forUbiquityContainerIdentifier: Self.container) {
      let docs = root.appendingPathComponent("Documents", isDirectory: true)
      try? fm.createDirectory(at: docs, withIntermediateDirectories: true)
      return (docs, .icloud)
    }
    let local = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Backups", isDirectory: true)
    try? fm.createDirectory(at: local, withIntermediateDirectories: true)
    return (local, .local)
  }

  private func location() -> [String: Any] {
    let f = folder()
    switch f.kind {
    case .custom:
      return ["label": f.url.lastPathComponent, "custom": true, "syncs": true]
    case .icloud:
      return ["label": "iCloud Drive › Voice Notes", "custom": false, "syncs": true]
    case .local:
      return [
        "label": "This iPhone only (sign in to iCloud Drive to sync)", "custom": false,
        "syncs": false,
      ]
    }
  }

  /// Runs [body] with access to a folder picked in Files.
  private func scoped<T>(_ url: URL, _ body: () throws -> T) rethrows -> T {
    let ok = url.startAccessingSecurityScopedResource()
    defer { if ok { url.stopAccessingSecurityScopedResource() } }
    return try body()
  }

  private func coordinated(read url: URL, _ body: (URL) throws -> Void) throws {
    var err: NSError?
    var inner: Error?
    NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &err) { u in
      do { try body(u) } catch { inner = error }
    }
    if let e = err ?? inner { throw e }
  }

  private func list() throws -> [[String: Any]] {
    let f = folder()
    return try scoped(f.url) {
      let items = try FileManager.default.contentsOfDirectory(
        at: f.url, includingPropertiesForKeys: [.contentModificationDateKey], options: [])
      var out: [[String: Any]] = []
      for u in items {
        var name = u.lastPathComponent
        // A file iCloud has not downloaded yet shows as ".name.icloud".
        if name.hasPrefix("."), name.hasSuffix(".icloud") {
          name = String(name.dropFirst().dropLast(".icloud".count))
        } else if name.hasPrefix(".") {
          continue
        }
        let date = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?
          .contentModificationDate ?? Date(timeIntervalSince1970: 0)
        out.append(["name": name, "modified": Int(date.timeIntervalSince1970 * 1000)])
      }
      return out
    }
  }

  private func read(_ name: String) throws -> String {
    let f = folder()
    let url = f.url.appendingPathComponent(name)
    return try scoped(f.url) {
      let fm = FileManager.default
      if !fm.fileExists(atPath: url.path) {
        try? fm.startDownloadingUbiquitousItem(at: url)
        // Wait for iCloud to bring the file down.
        for _ in 0..<60 where !fm.fileExists(atPath: url.path) {
          Thread.sleep(forTimeInterval: 0.5)
        }
      }
      var text = ""
      try coordinated(read: url) { u in text = try String(contentsOf: u, encoding: .utf8) }
      return text
    }
  }

  private func write(_ name: String, _ text: String) throws {
    let f = folder()
    let url = f.url.appendingPathComponent(name)
    let data = Data(text.utf8)
    try scoped(f.url) {
      var err: NSError?
      var inner: Error?
      NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &err) { u in
        do { try data.write(to: u, options: .atomic) } catch { inner = error }
      }
      if let e = err ?? inner { throw e }
    }
  }

  // MARK: Picking a folder

  private func pick(_ result: @escaping FlutterResult) {
    guard picking == nil else {
      return result(FlutterError(code: "busy", message: "Already choosing a folder", details: nil))
    }
    guard let top = Self.topController() else {
      return result(FlutterError(code: "pick", message: "Nothing to show the picker on", details: nil))
    }
    picking = result
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
    picker.delegate = self
    picker.allowsMultipleSelection = false
    top.present(picker, animated: true)
  }

  private static func topController() -> UIViewController? {
    let windows = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
    var top = (windows.first { $0.isKeyWindow } ?? windows.first)?.rootViewController
    while let shown = top?.presentedViewController { top = shown }
    return top
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let result = picking else { return }
    picking = nil
    guard let url = urls.first else { return result(nil) }
    do {
      let data = try scoped(url) { try url.bookmarkData() }
      defaults.set(data, forKey: Self.bookmarkKey)
      work(result) { self.location() }
    } catch {
      result(FlutterError(code: "pick", message: "Voice Notes cannot keep using that folder.", details: nil))
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    picking?(nil)
    picking = nil
  }
}
