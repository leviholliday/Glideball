import AppKit
import Observation

// The app's side of "Allow AI apps" (the rules are in AIApps.swift, the socket in
// AIAppsSocket.swift, the helper an AI app starts in AIAppsHelper.swift).
//
// The switch lives here and nowhere else: in memory, for 15 minutes from the person's
// click. It isn't a setting. It's never written to UserDefaults, a settings file, a share,
// sync or the opt-in stats, a setup code can't name it, and a relaunch always starts with
// it off. It goes off by itself when the time is up, when the Mac sleeps or the screen
// locks, when Glideball quits, and after three proposals in a row were turned down. It
// doesn't care whether Glideball is paused: it only ever changes settings.
//
// A proposal is a setup code, so it takes the road every setup code takes: read by
// `SetupCode.read`, shown in the review sheet (`IncomingSetup`, source `.aiApp`), applied
// by `AppModel.apply` with a "before AI setup" checkpoint and Undo, red-flagged shortcuts
// left out unless ticked. There is no second way to the settings here.

@Observable
final class AIAppsCenter: AIAppsHost {
    static let shared = AIAppsCenter()
    private init() {}

    /// The clock the 15 minutes run on. The self-test swaps it to let time pass.
    nonisolated(unsafe) static var clock: () -> Double = AIAppsClock.now

    /// Seconds until it turns itself off; 0 while it's off. What the switch and the countdowns show.
    private(set) var secondsLeft = 0
    /// The last try to turn it on couldn't open the socket file.
    private(set) var couldNotStart = false

    var isOn: Bool { secondsLeft > 0 }

    @ObservationIgnored private let gate = AIAppsGate(now: { AIAppsCenter.clock() })
    @ObservationIgnored private(set) lazy var service = AIAppsService(host: self, gate: gate, now: { AIAppsCenter.clock() })
    @ObservationIgnored private var listener: AIAppsListener?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var watching = false

    /// "14:32", for the countdown.
    var countdown: String { String(format: "%d:%02d", secondsLeft / 60, secondsLeft % 60) }

    // MARK: The switch

    /// At launch: a socket file a crash left behind goes (it's never listening again), and
    /// sleep and a locked screen are watched.
    func start() {
        guard !Sandbox.isActive, !watching else { return }
        watching = true
        var st = stat()
        let path = AIAppsHelper.socketPath
        if lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFSOCK, st.st_uid == getuid() { unlink(path) }
        let away: (Notification) -> Void = { _ in AIAppsCenter.shared.turnOff() }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main, using: away)
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main, using: away)
    }

    /// The person turned it on: 15 minutes from now.
    func turnOn() {
        couldNotStart = false
        if !Sandbox.isActive {
            listener?.stop()
            // Requests arrive on the socket's own queue and are answered on the main thread,
            // where the settings live.
            let l = AIAppsListener(path: AIAppsHelper.socketPath) { frame in
                DispatchQueue.main.sync {
                    AIAppsCenter.shared.reconcile()
                    return AIAppsCenter.shared.service.handle(frame)
                }
            }
            do {
                try l.start()
            } catch {
                listener = nil
                couldNotStart = true
                shutDown()
                return
            }
            listener = l
            timer?.invalidate()
            let t = Timer(timeInterval: 1, repeats: true) { _ in AIAppsCenter.shared.tick() }
            t.tolerance = 0.1
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
        gate.open()
        secondsLeft = Int(gate.remaining.rounded(.up))
    }

    /// The person turned it off (the switch, Stop), or Glideball is quitting, the Mac is going
    /// to sleep or the screen locked. A proposal that was waiting is taken down; nothing changes.
    func turnOff() {
        guard isOn || listener != nil || gate.isOpen else { return }
        shutDown()
    }

    /// Once a second while it's on (and by the self-test): the countdown, a proposal's five
    /// minutes, and the end of the fifteen.
    func tick() {
        reconcile()
        service.tick()
        let left = gate.remaining
        guard left > 0 else {
            if isOn || listener != nil {
                shutDown()
                AppModel.shared.show(.init(symbol: "clock.badge.checkmark", text: String(localized: "Allow AI apps turned itself off.", comment: "Toast when the 15 minutes of Allow AI apps are up")))
            }
            return
        }
        secondsLeft = Int(left.rounded(.up))
    }

    /// A proposal whose sheet went away without Apply or Cancel saying so (closed some other
    /// way) counts as turned down, so the next one isn't kept waiting behind it.
    private func reconcile() {
        guard let id = service.openProposal, AppModel.shared.pendingIncoming?.proposal != id else { return }
        service.resolved(proposal: id, applied: nil)
    }

    private func shutDown() {
        service.closeGate()   // refuses from here on, and takes a waiting proposal down
        listener?.stop()
        listener = nil
        timer?.invalidate()
        timer = nil
        secondsLeft = 0
    }

    // MARK: What the person did with a proposal

    /// The proposal is still the one waiting, and the switch is still on. Checked again at
    /// the moment of Apply, so a sheet that outlived either can't apply anything.
    func isWaiting(_ proposal: String) -> Bool {
        service.tick()
        return gate.isOpen && service.openProposal == proposal
    }

    func resolved(_ proposal: String, applied: [String]?, flaggedLeftOut: Int = 0) {
        service.resolved(proposal: proposal, applied: applied, flaggedLeftOut: flaggedLeftOut)
    }

    // MARK: AIAppsHost

    func setupForAI() -> String {
        let model = AppModel.shared
        return AIReference.forAIApp(setup: model.aiSetupCode(), device: model.setupDevice,
                                    showApps: !model.aiSetup.leaveAppNamesOut, version: GlideSettingsFile.appVersion)
    }

    var codeContext: SetupCode.Context { AppModel.shared.setupCodeContext }

    func review(_ reading: SetupCode.Reading) -> (changes: Int, flagged: Int) {
        let changes = AppModel.shared.changes(for: IncomingSetup(source: .aiApp(""), content: .shared(reading.share), leftOut: reading.notes))
        return (changes.count, changes.flatMap(\.risks).filter { $0.tier == .destructive }.count)
    }

    func present(_ reading: SetupCode.Reading, proposal: String, client: String) -> Bool {
        AppModel.shared.presentProposal(reading, id: proposal, client: client)
    }

    func withdraw(proposal: String) {
        AppModel.shared.withdrawProposal(proposal)
    }

    func turnedItselfOff() {
        shutDown()
        AppModel.shared.show(.init(symbol: "hand.raised.fill",
                                   text: String(localized: "Allow AI apps turned itself off after three suggestions you didn’t apply.",
                                                comment: "Toast when Allow AI apps switches off because the person turned down three proposals in a row")))
    }
}

extension AppModel {
    /// Shows an AI app's proposal in the review sheet, if nothing else is over the window.
    /// Unlike a link the person opened, it never waits its turn: if it can't show now, the
    /// AI app is told so. Glideball's window comes forward without becoming the active app,
    /// so whatever the person is typing keeps going where they're typing it.
    func presentProposal(_ reading: SetupCode.Reading, id: String, client: String) -> Bool {
        guard pendingIncoming == nil, queuedIncoming == nil, pendingImport == nil, shareRequest == nil, !incomingMustWait,
              ProcessInfo.processInfo.systemUptime - lastIncomingClosed >= Self.incomingCooldown else { return false }
        var incoming = IncomingSetup(source: .aiApp(client), content: .shared(reading.share), leftOut: reading.notes)
        incoming.proposal = id
        if !Sandbox.isActive { (NSApp.delegate as? AppDelegate)?.showWindow(activating: false, inFront: true) }
        pendingIncoming = incoming
        return true
    }

    /// A proposal's time is up, or Allow AI apps went off while it waited: its sheet closes.
    func withdrawProposal(_ id: String) {
        if queuedIncoming?.proposal == id { queuedIncoming = nil }
        guard pendingIncoming?.proposal == id else { return }
        pendingIncoming = nil
        lastIncomingClosed = ProcessInfo.processInfo.systemUptime
        show(.init(symbol: "clock", text: String(localized: "The AI app’s suggestion was taken down. Nothing changed.",
                                                 comment: "Toast when a proposal from an AI app expired or Allow AI apps went off while it waited")))
    }
}
