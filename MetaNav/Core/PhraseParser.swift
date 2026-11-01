import Foundation

/// How the wearer wants to get there.
enum TravelMode: String, Equatable, Sendable {
  case driving
  case walking
  case cycling
  case transit

  var word: String {
    switch self {
    case .driving: return "driving"
    case .walking: return "walking"
    case .cycling: return "biking"
    case .transit: return "transit"
    }
  }
}

/// What the wearer asked for, pulled out of a spoken sentence.
struct ParsedDestination: Equatable, Sendable {
  /// The place, as spoken, with the command words removed. Sent to the place search as-is.
  var query: String
  var mode: TravelMode
}

enum PhraseParser {
  /// Phrases that mean "start navigating", longest first so "start navigation to" wins
  /// over "navigate to".
  ///
  /// Every entry is lowercase and ends with "to", except the ones that take a place
  /// directly (see `directPrefixes`).
  private static let triggerPrefixes: [String] = [
    "start navigation to",
    "start navigating to",
    "start directions to",
    "give me directions to",
    "give me the directions to",
    "show me directions to",
    "show me the way to",
    "walking directions to",
    "driving directions to",
    "biking directions to",
    "cycling directions to",
    "transit directions to",
    "take transit to",
    "take the bus to",
    "take the train to",
    "take the subway to",
    // People often drop the "to": "take the bus downtown".
    "take the bus",
    "take the train",
    "take the subway",
    "take the metro",
    "navigate me to",
    "navigate to",
    "navigation to",
    "directions to",
    "take me to",
    "bring me to",
    "get me to",
    "drive me to",
    "drive to",
    "walk me to",
    "walk to",
    "bike to",
    "cycle to",
    "ride to",
    "route me to",
    "route to",
    "go to",
    "head to",
    "guide me to",
  ]

  /// "navigate starbucks" style, with no "to".
  private static let directPrefixes: [String] = [
    "navigate",
    "directions",
  ]

  /// Words we drop from the end of a request.
  private static let trailingFillers: [String] = [
    "please",
    "for me",
    "now",
  ]

  /// Leading filler that carries no meaning for a search.
  private static let leadingFillers: [String] = [
    "the",
    "a",
    "an",
  ]

  /// Things people say before the actual command.
  private static let leadingNoise: [String] = [
    "hey",
    "okay",
    "ok",
    "um",
    "uh",
    "so",
    "meta",
    "metanav",
  ]

  // MARK: - Destination

  /// Reads a spoken sentence and returns the place to navigate to, or `nil` when the
  /// sentence was not a navigation request.
  static func destination(from utterance: String) -> ParsedDestination? {
    var cleaned = normalize(utterance)
    guard !cleaned.isEmpty else { return nil }

    cleaned = stripLeadingNoise(cleaned)

    var rest: String?
    for prefix in triggerPrefixes where hasPrefix(cleaned, prefix) {
      rest = String(cleaned.dropFirst(prefix.count))
      break
    }

    if rest == nil {
      for prefix in directPrefixes where hasPrefix(cleaned, prefix) {
        rest = String(cleaned.dropFirst(prefix.count))
        break
      }
    }

    guard var query = rest else { return nil }
    query = trimFillers(query)
    guard !query.isEmpty else { return nil }
    guard query.count > 1 else { return nil }

    return ParsedDestination(query: query, mode: mode(in: utterance, fallback: .driving))
  }

  /// True when the wearer wants the current trip to end.
  static func isStopCommand(_ utterance: String) -> Bool {
    let cleaned = normalize(utterance)
    let stops = [
      "stop",
      "stop navigation",
      "stop navigating",
      "stop the navigation",
      "cancel navigation",
      "cancel the navigation",
      "end navigation",
      "end the navigation",
      "quit navigation",
      "exit navigation",
      "stop directions",
      "cancel directions",
      "stop guiding me",
      "stop the route",
      "i have arrived",
      "i'm here",
      "im here",
    ]
    if stops.contains(cleaned) { return true }
    // "stop" said as its own sentence inside a longer transcript.
    return cleaned.hasPrefix("stop navigation") || cleaned.hasPrefix("cancel navigation")
  }

  /// True when the wearer wants to back out of a choice.
  static func isCancelCommand(_ utterance: String) -> Bool {
    let cleaned = normalize(utterance)
    let cancels = [
      "cancel", "never mind", "nevermind", "forget it", "no", "nope",
      "stop", "none", "none of them", "neither",
    ]
    return cancels.contains(cleaned)
  }

  /// True when the wearer is asking to hear the current instruction again.
  static func isRepeatCommand(_ utterance: String) -> Bool {
    let cleaned = normalize(utterance)
    let repeats = [
      "repeat", "say again", "what", "what did you say", "again",
      "repeat that", "say that again", "pardon",
    ]
    return repeats.contains(cleaned)
  }

  // MARK: - Travel mode

  private static func mode(in utterance: String, fallback: TravelMode) -> TravelMode {
    let cleaned = normalize(utterance)
    let words = Set(cleaned.split(separator: " ").map(String.init))

    if words.contains("walk") || words.contains("walking") || cleaned.contains("on foot") {
      return .walking
    }
    if words.contains("bike") || words.contains("biking") || words.contains("cycle")
      || words.contains("cycling") || words.contains("bicycle")
    {
      return .cycling
    }
    if words.contains("transit") || words.contains("bus") || words.contains("train")
      || words.contains("subway") || words.contains("metro")
    {
      return .transit
    }
    if words.contains("drive") || words.contains("driving") || words.contains("car") {
      return .driving
    }
    return fallback
  }

  // MARK: - Text helpers

  /// Lowercase, punctuation trimmed, runs of spaces collapsed.
  static func normalize(_ text: String) -> String {
    var lowered = text.lowercased()
    lowered = lowered.replacingOccurrences(of: "\u{2019}", with: "'")
    let punctuation = CharacterSet(charactersIn: ".,!?;:\"“”")
    lowered = lowered.unicodeScalars
      .map { punctuation.contains($0) ? " " : String($0) }
      .joined()
    let parts = lowered.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
    return parts.joined(separator: " ")
  }

  private static func hasPrefix(_ text: String, _ prefix: String) -> Bool {
    guard text.hasPrefix(prefix) else { return false }
    // The prefix must end on a word boundary, so "go towards" is not "go to" + "wards".
    let next = text.index(text.startIndex, offsetBy: prefix.count)
    guard next < text.endIndex else { return true }
    return text[next] == " "
  }

  /// Drops "hey", "okay", "um" and similar from the front of a sentence.
  private static func stripLeadingNoise(_ text: String) -> String {
    var working = text
    var changed = true
    while changed {
      changed = false
      for noise in leadingNoise where working.hasPrefix(noise + " ") {
        working = String(working.dropFirst(noise.count + 1))
        changed = true
        break
      }
    }
    return working
  }

  private static func trimFillers(_ text: String) -> String {
    var working = text.trimmingCharacters(in: .whitespacesAndNewlines)

    var changed = true
    while changed {
      changed = false
      for filler in trailingFillers where working.hasSuffix(" " + filler) {
        working = String(working.dropLast(filler.count + 1))
        changed = true
      }
      if working == "please" { working = "" }
    }

    for filler in leadingFillers where working.hasPrefix(filler + " ") {
      working = String(working.dropFirst(filler.count + 1))
      break
    }

    return working.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
