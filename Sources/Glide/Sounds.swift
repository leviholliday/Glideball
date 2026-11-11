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

    /// The one switch for every sound above, and for the launch chime (Settings ›
    /// Look & Sound › Sounds). On by default.
    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? Self.migratedDefault() }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            // The launch chime and the intro's music still read "Launch sound"'s own key
            // (LaunchExperience), so it follows this switch.
            UserDefaults.standard.set(newValue, forKey: Self.oldLaunchKey)
            if Thread.isMainThread { LaunchExperience.shared.soundsOn = newValue }
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

    private func start(_ player: AVAudioPlayer) {
        player.volume = 1
        player.currentTime = 0
        player.play()
        current = player
    }

    /// Loaded on first use, then cached. Found like LaunchChime.m4a: in the app
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
