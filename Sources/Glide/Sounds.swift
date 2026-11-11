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

    /// The one switch for every sound above. On by default.
    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
    }

    private static let fade = 0.015
    private static let repeatWindow = 0.080

    private let queue = DispatchQueue(label: "com.leviholliday.glide.sounds", qos: .userInitiated)
    private let silentRun: Bool = {
        let args = CommandLine.arguments
        return args.contains("--render-ui") || args.contains("--self-test")
    }()

    // Only touched on `queue`.
    private var players: [Sound: AVAudioPlayer] = [:]
    private var missing: Set<Sound> = []
    private var current: AVAudioPlayer?
    private var lastRequest: (sound: Sound, at: TimeInterval)?
    private var generation = 0

    private init() {}

    func play(_ sound: Sound) {
        guard !silentRun, enabled else { return }
        let requested = ProcessInfo.processInfo.systemUptime
        queue.async { [self] in
            if let last = lastRequest, last.sound == sound, requested - last.at < Self.repeatWindow { return }
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
