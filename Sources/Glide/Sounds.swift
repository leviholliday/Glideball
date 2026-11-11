import AVFoundation
import Foundation

/// Glideball's small sound family ("glass marble"; made by scripts/make-sounds.py,
/// shipped as Resources/Sounds/*.caf, which build.sh and release.sh copy next to
/// the other sounds in the bundle's Resources).
enum Sound: String, CaseIterable {
    case resume
    case pause
    case modeOn = "mode-on"
    case modeOff = "mode-off"
    case tick
    case milestone
    case milestoneBig = "milestone-big"
    case hello
}

/// `Sounds.shared.play(.resume)`. Safe to call from anywhere, never blocks: the
/// work happens on a private serial queue. Never two at once (a new sound fades
/// the ringing one out over ~15 ms and then starts; the same sound twice within
/// 80 ms is dropped). Silent when the Mac is muted or turned all the way down,
/// when the one "Sounds" switch is off, and in `--render-ui` / `--self-test` runs.
final class Sounds: @unchecked Sendable {
    static let shared = Sounds()

    static let enabledKey = "GlideSounds"
    /// The two switches "Sounds" replaced (2.10): "Celebration sounds" and "Launch sound".
    static let oldCelebrationKey = "GlideCelebrationSounds"
    static let oldLaunchKey = "GlideLaunchSounds"

    /// The one switch for every sound above, "hello" after an update and the
    /// intro's music included (LaunchExperience reads it; Settings › Look & Sound ›
    /// Sounds). On by default.
    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? Self.migratedDefault() }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            // Kept in step with the old "Launch sound" key, so an older Glideball reads the same choice.
            UserDefaults.standard.set(newValue, forKey: Self.oldLaunchKey)
        }
    }

    /// The first time "Sounds" is read on a Mac that had the two old switches:
    /// it starts off if either was turned off by hand, and on otherwise. ("Celebration
    /// sounds" was off until you turned it on, so only an explicit off counts: someone
    /// who never touched it didn't say no to sounds.) Saved, so it's decided once.
    private static func migratedDefault() -> Bool {
        let d = UserDefaults.standard
        let launchOff = (d.object(forKey: oldLaunchKey) as? Bool) == false
        let celebrationsOff = (d.object(forKey: oldCelebrationKey) as? Bool) == false
        let on = !(launchOff || celebrationsOff)
        d.set(on, forKey: enabledKey)
        d.set(on, forKey: oldLaunchKey)
        return on
    }

    private static let fade = 0.015
    private static let repeatWindow = 0.080

    private let queue = DispatchQueue(label: "com.leviholliday.glide.sounds", qos: .userInitiated)
    private let silentRun: Bool = {
        let args = CommandLine.arguments
        return Sandbox.isActive || args.contains("--render-ui") || args.contains("--self-test")
    }()

    // Only touched on `queue`.
    private var players: [Sound: AVAudioPlayer] = [:]
    private var missing: Set<Sound> = []
    private var current: AVAudioPlayer?
    private var lastRequest: (sound: Sound, at: TimeInterval)?
    private var generation = 0

    private init() {}

    /// Plays `sound` if Sounds is on. `quietAfter`: skipped if any sound started in
    /// the last that many seconds (the "Saved" tick, so it never cuts off the sound
    /// of whatever was just done).
    func play(_ sound: Sound, quietAfter: TimeInterval = 0) {
        guard enabled else { return }
        play(sound, quietAfter: quietAfter, preview: false)
    }

    /// Settings' "Hear them" buttons: plays even with Sounds off (that's how you
    /// decide), but still never when the Mac is muted.
    func preview(_ sound: Sound) {
        play(sound, quietAfter: 0, preview: true)
    }

    private func play(_ sound: Sound, quietAfter: TimeInterval, preview: Bool) {
        guard !silentRun else { return }
        let requested = ProcessInfo.processInfo.systemUptime
        queue.async { [self] in
            if let last = lastRequest, last.sound == sound, requested - last.at < Self.repeatWindow { return }
            if quietAfter > 0, let last = lastRequest, requested - last.at < quietAfter { return }
            guard !LaunchExperience.systemOutputMuted, let player = player(for: sound) else { return }
            lastRequest = (sound, requested)
            generation += 1
            let mine = generation

            guard let old = current, old.isPlaying else {
                start(player)
                return
            }
            old.setVolume(0, fadeDuration: Self.fade)
            queue.asyncAfter(deadline: .now() + Self.fade + 0.003) { [self] in
                old.stop()
                old.volume = 1
                guard mine == generation else { return }   // a newer request took over
                start(player)
            }
        }
    }

    // MARK: Pitched ticks (slider detents, button press and release)

    // Only touched on `queue`.
    private var engine: AVAudioEngine?
    private var tickNode: AVAudioPlayerNode?
    private var varispeed: AVAudioUnitVarispeed?
    private var tickBuffer: AVAudioPCMBuffer?
    private var tickUnavailable = false
    private var lastDetent: TimeInterval = 0
    private var engineIdle: DispatchWorkItem?

    /// The soft tick, played faster and higher (`pitch` > 1) or slower and lower, and
    /// quieter than the other sounds: a slider's detents rise with its value, a press
    /// clicks and its release answers lower. Rate-limited (one every 45 ms at most), so
    /// a fast drag never chatters; on the same "Sounds" switch; silent when muted. The
    /// little audio engine behind it stops itself a second after the last tick.
    func detent(pitch: Double, volume: Float = 0.3) {
        guard enabled, !silentRun else { return }
        let requested = ProcessInfo.processInfo.systemUptime
        queue.async { [self] in
            guard requested - lastDetent >= 0.045, !LaunchExperience.systemOutputMuted else { return }
            // Never over a melody (a milestone, the hello chord): those win.
            if let current, current.isPlaying, let last = lastRequest, last.sound != .tick { return }
            guard let node = tickEngine() else { return }
            lastDetent = requested
            varispeed?.rate = Float(min(max(pitch, 0.5), 2))
            node.volume = min(max(volume, 0), 1)
            node.scheduleBuffer(tickBuffer!, at: nil, options: .interrupts)
            if !node.isPlaying { node.play() }
            engineIdle?.cancel()
            let idle = DispatchWorkItem { [weak self] in
                self?.tickNode?.stop()
                self?.engine?.stop()
            }
            engineIdle = idle
            queue.asyncAfter(deadline: .now() + 1.2, execute: idle)
        }
    }

    private func tickEngine() -> AVAudioPlayerNode? {
        if let engine, let tickNode {
            if !engine.isRunning { try? engine.start() }
            return engine.isRunning ? tickNode : nil
        }
        guard !tickUnavailable,
              let url = Bundle.main.url(forResource: Sound.tick.rawValue, withExtension: "caf"),
              let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil else {
            tickUnavailable = true
            return nil
        }
        let e = AVAudioEngine(), node = AVAudioPlayerNode(), speed = AVAudioUnitVarispeed()
        e.attach(node)
        e.attach(speed)
        e.connect(node, to: speed, format: buffer.format)
        e.connect(speed, to: e.mainMixerNode, format: buffer.format)
        do { try e.start() } catch { tickUnavailable = true; return nil }
        engine = e; tickNode = node; varispeed = speed; tickBuffer = buffer
        return node
    }

    private func start(_ player: AVAudioPlayer) {
        player.volume = 1
        player.currentTime = 0
        player.play()
        current = player
    }

    /// Loaded on first use, then cached. Found like IntroMusic.m4a: in the app
    /// bundle's Resources (so a bare `swift run` is simply silent).
    private func player(for sound: Sound) -> AVAudioPlayer? {
        if let p = players[sound] { return p }
        guard !missing.contains(sound) else { return nil }
        guard let url = Bundle.main.url(forResource: sound.rawValue, withExtension: "caf"),
              let p = try? AVAudioPlayer(contentsOf: url) else {
            missing.insert(sound)
            return nil
        }
        p.prepareToPlay()
        players[sound] = p
        return p
    }
}
