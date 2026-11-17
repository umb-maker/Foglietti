import AppKit
import AVFoundation
import NaturalLanguage

/// Sound playback: macOS system sounds, the user's own audio files, and speech.
///
/// A sound is identified by a string: "" = silent, a bare name = system sound (e.g. "Glass"),
/// an absolute path = a custom audio file.
@MainActor
enum Sounds {
    enum UI { case tick, done, trash }

    /// System sounds plus the ones the user added to ~/Library/Sounds.
    static var available: [String] {
        let dirs = ["/System/Library/Sounds", NSString(string: "~/Library/Sounds").expandingTildeInPath]
        let names = dirs.flatMap { (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? [] }
            .filter { ["aiff", "aif", "wav", "caf", "mp3", "m4a"].contains(($0 as NSString).pathExtension.lowercased()) }
            .map { ($0 as NSString).deletingPathExtension }
        return Array(Set(names)).sorted()
    }

    static func displayName(_ id: String) -> String {
        if id.isEmpty { return L("None") }
        if id.hasPrefix("/") { return (id as NSString).lastPathComponent }
        return id
    }

    /// Sounds currently playing: NSSound stops if it is deallocated.
    private static var playing: [NSSound] = []

    static func play(_ id: String, volume: Double) {
        guard !id.isEmpty else { return }
        let sound = id.hasPrefix("/") ? NSSound(contentsOf: URL(fileURLWithPath: id), byReference: true) : NSSound(named: NSSound.Name(id))
        guard let sound else { return }
        sound.volume = Float(max(0, min(1, volume)))
        playing.removeAll { !$0.isPlaying }
        playing.append(sound)
        sound.play()
    }

    /// Short interface sounds, off by default.
    static func ui(_ kind: UI) {
        let s = NoteStore.shared.settings
        guard s.uiSounds, !inQuietHours(s) else { return }
        switch kind {
        case .tick: play("Tink", volume: s.soundVolume * 0.5)
        case .done: play("Glass", volume: s.soundVolume * 0.4)
        case .trash: play("Pop", volume: s.soundVolume * 0.5)
        }
    }

    // MARK: Speech

    private static let synth = AVSpeechSynthesizer()

    /// Reads a text aloud with the system voice for its language (works offline).
    static func speak(_ text: String, volume: Double) {
        let u = AVSpeechUtterance(string: text)
        if let lang = Translator.detect(text) { u.voice = AVSpeechSynthesisVoice(language: lang) }
        u.volume = Float(max(0, min(1, volume)))
        synth.stopSpeaking(at: .immediate)
        synth.speak(u)
    }

    // MARK: Quiet hours

    /// True inside the quiet hours (which may cross midnight, e.g. 22:00–07:00).
    static func inQuietHours(_ s: AppSettings, at date: Date = Date()) -> Bool {
        guard s.quietHoursEnabled else { return false }
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        let now = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        let from = s.quietFrom, to = s.quietTo
        return from <= to ? (now >= from && now < to) : (now >= from || now < to)
    }

    /// Lets the user pick an audio file; returns its path.
    static func chooseFile() -> String? {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.audio]
        p.message = L("Choose a sound file")
        NSApp.activate(ignoringOtherApps: true)
        return p.runModal() == .OK ? p.url?.path : nil
    }
}
