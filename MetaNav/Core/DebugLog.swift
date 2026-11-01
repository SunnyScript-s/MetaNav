import Foundation

/// A tiny log kept inside the app's own Documents folder.
///
/// The phone is the only place the glasses and Meta AI can be seen misbehaving, so the
/// app writes down what it asked for and what came back. The file is pulled off the
/// phone with `devicectl device copy from`; nothing is ever sent anywhere.
enum DebugLog {
  private static let queue = DispatchQueue(label: "com.santiagoharbison.metanav.debuglog")
  private static let maxBytes: UInt64 = 200_000

  static var fileURL: URL? {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
      .appendingPathComponent("metanav-log.txt")
  }

  static func write(_ message: String) {
    #if DEBUG
      queue.async {
        guard let url = fileURL else { return }
        let line = "\(stamp()) \(message)\n"
        let data = Data(line.utf8)

        guard FileManager.default.fileExists(atPath: url.path) else {
          try? data.write(to: url, options: .atomic)
          return
        }

        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return }
        try? handle.write(contentsOf: data)

        // Keep the file small: drop the oldest half once it gets long.
        if size > maxBytes {
          try? handle.truncateFile(atOffset: maxBytes / 2)
        }
      }
    #endif
  }

  private static func stamp() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    return formatter.string(from: Date())
  }
}
