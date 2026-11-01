import AVFoundation
import Foundation

/// Speaks the guidance out loud.
///
/// On iOS the glasses are a normal Bluetooth audio device, so anything played here comes
/// out of them once they are paired. That is the whole trick: no special API needed for
/// the voice.
@MainActor
final class Speaker: NSObject {
  private let synthesizer = AVSpeechSynthesizer()
  private var onFinish: (() -> Void)?
  /// The line currently being spoken, so a late callback from an interrupted one cannot
  /// clear the state of the one that replaced it.
  private var currentUtterance: AVSpeechUtterance?

  /// True while words are coming out, so the microphone can be left alone meanwhile.
  private(set) var isSpeaking = false

  override init() {
    super.init()
    synthesizer.delegate = self
  }

  /// Called once at launch. `.playback` keeps working with the screen locked.
  ///
  /// The session is *not* activated here. Activating it would duck the wearer's music from
  /// the moment the app opens, even though nothing is being said. It is activated for the
  /// length of each instruction instead — see `activate()`.
  func configureAudioSession() {
    #if os(iOS)
    do {
      // `.allowBluetoothHFP` keeps the voice on the glasses when they are also acting as
      // the microphone (hands-free profile), which is the normal case here.
      try AVAudioSession.sharedInstance().setCategory(
        .playback,
        mode: .spokenAudio,
        options: [.duckOthers, .allowBluetoothHFP]
      )
    } catch {
      // Not fatal: the app still works, it is just quieter about it.
    }
    #endif
  }

  private func activate() {
    #if os(iOS)
    try? AVAudioSession.sharedInstance().setActive(true, options: [])
    #endif
  }

  private func deactivate() {
    #if os(iOS)
    try? AVAudioSession.sharedInstance().setActive(
      false,
      options: [.notifyOthersOnDeactivation]
    )
    #endif
  }

  func speak(_ text: String, then completion: (() -> Void)? = nil) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      completion?()
      return
    }

    // A new instruction replaces whatever is still being said. Cutting off an old
    // instruction is right; queueing two turns behind each other is not.
    if synthesizer.isSpeaking {
      onFinish = nil
      synthesizer.stopSpeaking(at: .immediate)
    }

    let utterance = AVSpeechUtterance(string: trimmed)
    utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
    utterance.rate = 0.48
    utterance.pitchMultiplier = 1.0
    utterance.postUtteranceDelay = 0.05

    onFinish = completion
    currentUtterance = utterance
    isSpeaking = true
    activate()
    synthesizer.speak(utterance)
  }

  func stop() {
    onFinish = nil
    currentUtterance = nil
    isSpeaking = false
    if synthesizer.isSpeaking {
      synthesizer.stopSpeaking(at: .immediate)
    }
    deactivate()
  }
}

extension Speaker: AVSpeechSynthesizerDelegate {
  nonisolated func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer,
    didFinish utterance: AVSpeechUtterance
  ) {
    Task { @MainActor in
      // A callback for a line that has already been replaced is not news.
      guard self.currentUtterance === utterance else { return }
      self.currentUtterance = nil
      self.isSpeaking = false
      let completion = self.onFinish
      self.onFinish = nil
      // Let the wearer's music come back up between instructions.
      self.deactivate()
      completion?()
    }
  }

  nonisolated func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer,
    didCancel utterance: AVSpeechUtterance
  ) {
    Task { @MainActor in
      // A cancel that lands just as the next instruction starts must not clear the
      // "busy" flag, or the microphone would be switched back on mid-sentence.
      if !self.synthesizer.isSpeaking {
        self.isSpeaking = false
      }
    }
  }
}
