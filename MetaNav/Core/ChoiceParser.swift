import Foundation

/// Reads "the second one" and turns it into a zero-based index.
///
/// Kept separate and pure because it is the one part of the choice flow that has to be
/// exactly right: a wrong pick sends someone to the wrong place.
enum ChoiceParser {
  /// Returns the zero-based index the wearer picked, or `nil` when the answer was not a
  /// usable choice.
  static func index(from utterance: String, optionCount: Int) -> Int? {
    guard optionCount > 0 else { return nil }

    let words = PhraseParser.normalize(utterance).split(separator: " ").map(String.init)
    guard !words.isEmpty else { return nil }

    if words.contains("last") || words.contains("final") {
      return optionCount - 1
    }

    for word in words {
      if let number = number(from: word) {
        guard number >= 1, number <= optionCount else { return nil }
        return number - 1
      }
    }

    // A bare "yes" or "okay" means the first one, which is the one read out first.
    let affirmatives: Set<String> = ["yes", "yeah", "yep", "ok", "okay", "sure", "first"]
    if words.contains(where: affirmatives.contains) { return 0 }

    return nil
  }

  /// Digits and spoken ordinals/cardinals, 1-based.
  private static func number(from word: String) -> Int? {
    switch word {
    case "1", "one", "first", "1st": return 1
    case "2", "two", "second", "2nd": return 2
    case "3", "three", "third", "3rd": return 3
    case "4", "four", "fourth", "4th": return 4
    case "5", "five", "fifth", "5th": return 5
    default: return nil
    }
  }
}
