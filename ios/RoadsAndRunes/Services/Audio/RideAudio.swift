import AVFoundation
import RoadsAndRunesCore

/// The ride's sounds: short chimes, and (when asked for) a voice.
///
/// A ride is ridden with the phone in a pocket, and until this everything it had
/// to say it said on the screen. The chimes are made here from their notes — a
/// sine, an overtone and a decay is a small bell — so there are no sound files to
/// ship and new ground can climb a scale as far as the ride does. They mix with
/// whatever is playing; the voice ducks it for as long as a line takes and lets
/// it back up after.
@MainActor
final class RideAudio: NSObject {
    /// Called when a spoken line has finished, so the next can take its turn.
    var onFinishedSpeaking: (() -> Void)?
    private(set) var isSpeaking = false
    /// When the last chime scheduled will have finished.
    private var chimeEndsAt = Date.distantPast
    /// Something is being heard now: a line, or a chime still ringing.
    var isBusy: Bool { isSpeaking || Date() < chimeEndsAt }

    private let enabled: Bool
    private let modeProvider: () -> RideSound
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)
    private let synthesizer = AVSpeechSynthesizer()
    private var buffers: [String: AVAudioPCMBuffer] = [:]
    private var attached = false
    private var ducking = false

    /// `enabled` is false in tests and previews: nothing touches the audio session.
    init(enabled: Bool, mode: @escaping () -> RideSound) {
        self.enabled = enabled
        self.modeProvider = mode
        super.init()
        synthesizer.delegate = self
    }

    var mode: RideSound { modeProvider() }

    /// A ride is starting: get the session ready so the first chime is not late.
    func start() {
        guard enabled, mode != .off else { return }
        activate(ducking: false)
    }

    /// The ride is over: give the audio back.
    func stop() {
        guard enabled else { return }
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
        player.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func play(_ chime: RideChime, step: Int = 0) {
        guard enabled, mode != .off, let buffer = buffer(for: chime, step: step) else { return }
        // A line being spoken has the session ducked; the chime plays under it.
        activate(ducking: isSpeaking)
        guard engine.isRunning else { return }
        player.scheduleBuffer(buffer, at: nil, options: [])
        if !player.isPlaying { player.play() }
        chimeEndsAt = max(chimeEndsAt, Date()).addingTimeInterval(chime.length(step: step))
    }

    func speak(_ line: String) {
        guard enabled, mode == .voice else { return }
        activate(ducking: true)
        let utterance = AVSpeechUtterance(string: line)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-GB")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.98
        utterance.preUtteranceDelay = 0.15
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    /// One chime, for the setting to be heard before it is chosen.
    func preview(_ sound: RideSound) {
        guard enabled, sound != .off else { return }
        activate(ducking: false)
        if let buffer = buffer(for: .win, step: 0), engine.isRunning {
            player.scheduleBuffer(buffer, at: nil, options: [])
            if !player.isPlaying { player.play() }
        }
        guard sound == .voice else { return }
        let utterance = AVSpeechUtterance(string: "Bog Wraith, gone. 60 coins.")
        utterance.voice = AVSpeechSynthesisVoice(language: "en-GB")
        utterance.preUtteranceDelay = 0.9
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    /// A fight, played as a ride would play it, for hearing it on a road before
    /// one is met (docs/FIELD_TESTS.md): it notices you, a rune lands, it is gone.
    /// `onBeat` is given the wrist taps, for the Watch.
    func playScriptedFight(onBeat: @escaping (FightBeat) -> Void = { _ in }) {
        guard enabled, mode != .off else { return }
        let steps: [(event: RideEvent, beat: FightBeat?, after: Double)] = [
            (.engaged(name: "Grey Stag", wants: ["CLIMB", "RUNE"]), .engaged, 0.3),
            (.landed(name: "Grey Stag", kind: "RUNE"), nil, 5),
            (.claimed(name: "Grey Stag", kind: .monster, coins: 120, set: nil), nil, 5),
        ]
        Task { @MainActor [weak self] in
            for step in steps {
                try? await Task.sleep(for: .milliseconds(Int(step.after * 1000)))
                guard let self else { return }
                if let chime = step.event.chime { self.play(chime, step: step.event.chimeStep) }
                if let beat = step.beat { onBeat(beat) }
                if self.mode == .voice, let line = step.event.spoken() { self.speak(line) }
            }
        }
    }

    // MARK: Session and engine

    private func activate(ducking wanted: Bool) {
        let session = AVAudioSession.sharedInstance()
        do {
            if wanted != ducking || session.category != .playback {
                let options: AVAudioSession.CategoryOptions = wanted ? [.duckOthers, .interruptSpokenAudioAndMixWithOthers] : [.mixWithOthers]
                try session.setCategory(.playback, mode: wanted ? .voicePrompt : .default, options: options)
                ducking = wanted
            }
            try session.setActive(true)
            if !attached, let format {
                engine.attach(player)
                engine.connect(player, to: engine.mainMixerNode, format: format)
                attached = true
            }
            if !engine.isRunning { try engine.start() }
        } catch {
            AppLog.navigation.warning("ride_audio_unavailable \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Synthesis

    private func buffer(for chime: RideChime, step: Int) -> AVAudioPCMBuffer? {
        let key = "\(chime.rawValue)-\(chime == .newGround ? step : 0)"
        if let cached = buffers[key] { return cached }
        guard let format else { return nil }
        let notes = chime.notes(step: step)
        let sampleRate = format.sampleRate
        let frames = AVAudioFrameCount((chime.length(step: step) + 0.05) * sampleRate)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames), let samples = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frames
        for index in 0..<Int(frames) { samples[index] = 0 }
        for note in notes {
            let first = Int(note.start * sampleRate)
            let count = Int(note.duration * sampleRate)
            // Down to about a hundredth by the end of the note: a struck bell, not a held tone.
            let decay = 4.6 / note.duration
            for offset in 0..<count where first + offset < Int(frames) {
                let t = Double(offset) / sampleRate
                let attack = min(1, t / 0.004)
                let envelope = attack * exp(-decay * t)
                let tone = sin(2 * .pi * note.frequency * t) + 0.3 * sin(2 * .pi * note.frequency * 2 * t) + 0.12 * sin(2 * .pi * note.frequency * 3 * t)
                samples[first + offset] += Float(note.gain * envelope * tone / 1.42)
            }
        }
        // Several notes can land on one another; keep the sum inside the rails.
        var peak: Float = 0
        for index in 0..<Int(frames) { peak = max(peak, abs(samples[index])) }
        if peak > 0.9 {
            let scale = 0.9 / peak
            for index in 0..<Int(frames) { samples[index] *= scale }
        }
        buffers[key] = buffer
        return buffer
    }
}

extension RideAudio: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finished() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finished() }
    }

    private func finished() {
        guard isSpeaking else { return }
        isSpeaking = false
        // Let whatever was playing back up: the duck lifts when the session that asked
        // for it stands down. Then be ready for the next chime.
        player.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        activate(ducking: false)
        onFinishedSpeaking?()
    }
}
