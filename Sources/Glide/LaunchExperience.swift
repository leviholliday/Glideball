import AppKit
import AVFoundation
import CoreAudio
import Observation

/// What plays over the window when Glide starts (the views are in
/// `LaunchViews.swift`):
///
/// - The very first launch on a Mac that has never used Glide: a ~7 s
///   cinematic intro with its own music (IntroMusic.m4a), after which the
///   window's glass dissolves in and the Welcome Tour opens.
/// - Every other cold launch that opens the window: a short (~1.5 s) glass
///   animation, a different one each time, with an optional soft chime.
///
/// Neither ever holds anything up: the engine is already running before the
/// window opens, only the window's contents wait. A click or esc skips.
/// Reopening a closed window, or a launch at login that opens no window,
/// shows nothing.
///
/// Debugging:
///   defaults write com.leviholliday.glide GlideForceIntro -bool YES
///       plays the intro on the next launch (once)
///   defaults write com.leviholliday.glide GlideForceSplashVariant -int <0…5>
///       always plays that launch animation (`defaults delete` to go back)
@Observable
final class LaunchExperience {
    static let shared = LaunchExperience()

    static let introPlayedKey = "GlideIntroPlayed"
    static let forceIntroKey = "GlideForceIntro"
    static let forceVariantKey = "GlideForceSplashVariant"
    static let lastVariantKey = "GlideLastSplashVariant"
    static let soundsKey = "GlideLaunchSounds"

    enum Show: Equatable {
        case intro
        case splash(SplashVariant)
    }

    /// What's over the window right now; nil once it has gone.
    private(set) var show: Show?
    /// When it started playing (its first frame on screen).
    private(set) var start: Date?
    /// When the window's contents started dissolving in, and over how long.
    private(set) var revealStart: Date?
    private(set) var revealDuration: Double = 0.45

    /// "Launch sounds" in Overview › General. On by default.
    var soundsOn: Bool {
        didSet { defaults.set(soundsOn, forKey: Self.soundsKey) }
    }

    /// The window's contents are drawn (from the start of the reveal on).
    var contentReady: Bool { show == nil || revealStart != nil }
    var isIntro: Bool { show == .intro }
    var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var openTourWhenDone = false
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var generation = 0

    private init() {
        soundsOn = defaults.object(forKey: Self.soundsKey) as? Bool ?? true
    }

    // MARK: Timing

    /// When the reveal starts by itself, in seconds from the first frame.
    var revealAt: Double {
        switch show {
        case .intro: reduceMotion ? 2.6 : 6.4
        case .splash: reduceMotion ? 0.55 : 1.1
        case nil: 0
        }
    }

    private var naturalRevealDuration: Double {
        switch show {
        case .intro: reduceMotion ? 0.5 : 0.95
        default: reduceMotion ? 0.3 : 0.5
        }
    }

    // MARK: Launch

    /// Called once, at launch, before the window opens. `firstLaunch` is a Mac
    /// that has never used Glide (no saved settings); `showsWindow` is false
    /// for a quiet launch at login. Returns whether the intro will play (it
    /// then opens the Welcome Tour itself when it's done).
    @discardableResult
    func prepare(firstLaunch: Bool, showsWindow: Bool) -> Bool {
        let forced = defaults.bool(forKey: Self.forceIntroKey)
        if forced { defaults.removeObject(forKey: Self.forceIntroKey) }   // once
        guard showsWindow, !CommandLine.arguments.contains("--no-launch-animation") else { return false }

        if forced || (firstLaunch && !defaults.bool(forKey: Self.introPlayedKey)) {
            show = .intro
            openTourWhenDone = firstLaunch
            defaults.set(true, forKey: Self.introPlayedKey)
            preparePlayer("IntroMusic", volume: 0.6)
        } else {
            show = .splash(nextVariant())
            preparePlayer("LaunchChime", volume: 0.32)
        }
        installKeyMonitor()
        return show == .intro
    }

    /// Random, never the same twice in a row (unless one is forced).
    private func nextVariant() -> SplashVariant {
        if defaults.object(forKey: Self.forceVariantKey) != nil,
           let forced = SplashVariant(rawValue: defaults.integer(forKey: Self.forceVariantKey)) {
            return forced
        }
        let last = defaults.object(forKey: Self.lastVariantKey) as? Int
        let pick = SplashVariant.allCases.filter { $0.rawValue != last }.randomElement() ?? .ringIgnition
        defaults.set(pick.rawValue, forKey: Self.lastVariantKey)
        return pick
    }

    /// The overlay's first frame is on screen: start the clock and the sound.
    func began() {
        guard show != nil, start == nil else { return }
        start = Date()
        if soundsOn, !Self.systemOutputMuted, let player {
            player.play()
        } else {
            player = nil
        }
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + revealAt) { [weak self] in
            guard let self, self.generation == gen else { return }
            self.reveal(over: self.naturalRevealDuration)
        }
    }

    /// A click or esc: straight to the reveal, quickly.
    func skip() {
        guard show != nil, revealStart == nil else { return }
        if start == nil { start = Date() }
        reveal(over: reduceMotion ? 0.2 : 0.35)
    }

    private func reveal(over duration: Double) {
        guard show != nil, revealStart == nil else { return }
        generation += 1
        revealDuration = duration
        revealStart = Date()
        // The music rings on a little past the picture, fading.
        if let player, player.isPlaying {
            let elapsed = start.map { Date().timeIntervalSince($0) } ?? 0
            let skipped = elapsed < revealAt - 0.05
            let fade = skipped ? 0.45 : max(0.6, player.duration - player.currentTime)
            player.setVolume(0, fadeDuration: fade)
            let p = player
            DispatchQueue.main.asyncAfter(deadline: .now() + fade + 0.1) { [weak self] in
                p.stop()
                if self?.player === p { self?.player = nil }
            }
        }
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, self.generation == gen else { return }
            self.finish()
        }
    }

    private func finish() {
        guard show != nil else { return }
        show = nil
        start = nil
        revealStart = nil
        removeKeyMonitor()
        if openTourWhenDone {
            openTourWhenDone = false
            // Only into a window that's still open (closing it skips the tour
            // for now; it opens next launch, as it hasn't been finished).
            let windowOpen = NSApp.windows.contains { $0.isVisible && $0.frameAutosaveName == "GlideMain" }
            if windowOpen {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    AppModel.shared.showWelcomeTour()
                }
            }
        }
    }

    // MARK: Sound

    private func preparePlayer(_ name: String, volume: Float) {
        guard soundsOn, let url = Bundle.main.url(forResource: name, withExtension: "m4a"),
              let p = try? AVAudioPlayer(contentsOf: url) else { return }
        p.volume = volume
        p.prepareToPlay()
        player = p
    }

    /// Whether the Mac's sound output is muted (or turned all the way down):
    /// then the launch stays silent rather than relying on the mixer.
    static var systemOutputMuted: Bool {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return false }

        address.mScope = kAudioDevicePropertyScopeOutput
        address.mSelector = kAudioDevicePropertyMute
        var muted: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectHasProperty(device, &address),
           AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted) == noErr, muted != 0 {
            return true
        }
        address.mSelector = kAudioDevicePropertyVolumeScalar
        var volume: Float32 = 1
        size = UInt32(MemoryLayout<Float32>.size)
        if AudioObjectHasProperty(device, &address),
           AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume) == noErr, volume < 0.001 {
            return true
        }
        return false
    }

    // MARK: Esc

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.show != nil, event.keyCode == 53 else { return event }   // esc
            self.skip()
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

/// The short launch animations. One plays per cold launch, never the same
/// one twice running.
enum SplashVariant: Int, CaseIterable {
    /// The scroll ring's ridges light up in turn as it spins up.
    case ringIgnition
    /// The ball rolls in over a glass floor, its reflection beneath.
    case ballRoll
    /// Sparks swirl inward and condense into the trackball.
    case particleSwirl
    /// Liquid-glass ripples spread out and the trackball wobbles into place.
    case ripple
    /// The six tab icons ride a wave across, then gather into the trackball.
    case tabWave
    /// Streaks flick past, like a spin of the ring, and the trackball
    /// glides in on momentum.
    case flick
}
