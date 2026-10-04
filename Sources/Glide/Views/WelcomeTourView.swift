import AppKit
import SwiftUI

/// A six-step walkthrough over the whole window: welcome, permissions, meet
/// your buttons, scrolling and pointer speed, safety, done. Return / → go on,
/// ← goes back, esc closes. Opened by `AppModel.showingWelcomeTour`.
struct WelcomeTourView: View {
    @Bindable var model: AppModel

    enum Step: Int, CaseIterable, Identifiable {
        case welcome, permissions, buttons, scrolling, safety, done
        var id: Int { rawValue }
    }

    @State private var step: Step = .welcome
    @State private var forward = true
    @State private var found: Set<Int> = []
    @FocusState private var focused: Bool
    @Environment(\.appearsActive) private var appearsActive

    private static let buttons: [(index: Int, name: String, normally: String)] = (0..<4).map {
        ($0, AppModel.buttonName($0), AppModel.buttonDefault($0))
    }

    var body: some View {
        ZStack {
            GlideBackground()
            panel
                .padding(.horizontal, 40)
                .padding(.top, 40)
                .padding(.bottom, 28)
        }
        .contentShape(Rectangle())   // nothing underneath can be clicked
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { back(); return .handled }
        .onKeyPress(.rightArrow) { if canAdvance { advance() }; return .handled }
        .onAppear {
            focused = true
            updateButtonSuspension()
        }
        .onDisappear { model.suspendButtonMappings(false) }
        .onChange(of: step) { updateButtonSuspension() }
        .onChange(of: appearsActive) { updateButtonSuspension() }
        .onChange(of: model.pressed) { _, now in
            guard step == .buttons else { return }
            let new = now.intersection(0..<4).subtracting(found)
            if !new.isEmpty { withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { found.formUnion(new) } }
        }
    }

    // MARK: Frame

    private var panel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Welcome Tour")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.6)
                Spacer()
                Button(action: model.closeWelcomeTour) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .keyboardShortcut(.cancelAction)
                .help("Close the tour (esc) — reopen it from Help › Show Welcome Tour…")
                .accessibilityLabel("Close tour")
            }

            ZStack {
                page(step)
                    .id(step)
                    .transition(.asymmetric(
                        insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                        removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .padding(.vertical, 12)

            footer
        }
        .padding(26)
        .frame(maxWidth: 840, maxHeight: 620)
        .glassEffect(.regular, in: .rect(cornerRadius: 34))
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if step != .welcome {
                Button(action: back) {
                    Label("Back", systemImage: "chevron.left").padding(.horizontal, 4)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
            }
            Spacer()
            if step == .permissions && !model.permissionsOK {
                Button("Skip for now") { advance(force: true) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Glide stays out of the way until both permissions are on")
            }
            Button(action: { advance() }) {
                HStack(spacing: 6) {
                    Text(nextTitle)
                    if step != .done { Image(systemName: "chevron.right") }
                }
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 8)
            }
            .buttonStyle(.glassProminent)
            .tint(.cyan)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(!canAdvance)
        }
        .overlay { dots }
    }

    private var dots: some View {
        HStack(spacing: 7) {
            ForEach(Step.allCases) { s in
                Capsule()
                    .fill(s == step ? Color.primary.opacity(0.85) : Color.primary.opacity(0.22))
                    .frame(width: s == step ? 22 : 7, height: 7)
            }
        }
        .animation(.smooth(duration: 0.3), value: step)
        .accessibilityElement()
        .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count)")
    }

    private var nextTitle: String {
        switch step {
        case .welcome: String(localized: "Get Started")
        case .done: String(localized: "Start Using Glide")
        default: String(localized: "Continue")
        }
    }

    private var canAdvance: Bool { step != .permissions || model.permissionsOK }

    private func advance(force: Bool = false) {
        guard force || canAdvance else { return }
        guard let next = Step(rawValue: step.rawValue + 1) else {
            model.closeWelcomeTour()
            return
        }
        go(to: next, forward: true)
    }

    private func back() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        go(to: previous, forward: false)
    }

    /// Sets the direction first, so the page leaving slides the right way too.
    private func go(to target: Step, forward: Bool) {
        self.forward = forward
        DispatchQueue.main.async {
            withAnimation(.smooth(duration: 0.35)) { step = target }
        }
    }

    /// Only while "Meet your buttons" is on screen in the active window.
    private func updateButtonSuspension() {
        model.suspendButtonMappings(step == .buttons && appearsActive)
    }

    // MARK: Pages

    @ViewBuilder private func page(_ step: Step) -> some View {
        switch step {
        case .welcome: welcomePage
        case .permissions: permissionsPage
        case .buttons: buttonsPage
        case .scrolling: scrollingPage
        case .safety: safetyPage
        case .done: donePage
        }
    }

    private func header(_ symbol: String, _ title: LocalizedStringKey, _ subtitle: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.cyan)
                .frame(width: 46, height: 46)
                .glassEffect(.regular.tint(.cyan.opacity(0.18)), in: .rect(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 24, weight: .bold, design: .rounded))
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    // 1. Welcome

    private var welcomePage: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 120, height: 120)
                .shadow(color: .cyan.opacity(0.45), radius: 30)
            Text("Welcome to Glide")
                .font(.system(size: 36, weight: .bold, design: .rounded))
            Text("Your Kensington trackball, tuned exactly the way you like it.")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 10) {
                    feature("cursorarrow.motionlines", "A faster pointer")
                    feature("arrow.up.and.down.circle", "A silky scroll ring")
                    feature("button.programmable", "Buttons that do more")
                }
            }
            .padding(.top, 8)
            Spacer(minLength: 0)
            Text("About a minute. Use Return or the arrow keys to move along.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }

    private func feature(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .glassEffect(.regular, in: .capsule)
    }

    // 2. Permissions

    private var permissionsPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            header("lock.shield", "Two quick permissions",
                   "Glide needs these to read your trackball and change what it does. Until both are on, your trackball works normally and Glide stays out of the way.")
            permissionRow("Accessibility", symbol: "accessibility",
                          detail: "Lets Glide change what your buttons and scroll ring do.",
                          granted: model.hasAccessibility, action: model.requestAccessibility)
            permissionRow("Input Monitoring", symbol: "keyboard.badge.eye",
                          detail: "Lets Glide tell your trackball apart from your other mice and trackpad.",
                          granted: model.hasInputMonitoring, action: model.requestInputMonitoring)
            Spacer(minLength: 0)
            Group {
                if model.permissionsOK {
                    Label("All set — Glide can see your trackball.", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("Switch Glide on in each list in System Settings, then come back — the checkmarks update by themselves.",
                          systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 12, weight: .medium))
            .animation(.smooth, value: model.permissionsOK)
        }
    }

    private func permissionRow(_ name: LocalizedStringKey, symbol: String, detail: LocalizedStringKey, granted: Bool,
                               action: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .medium))
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 15, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Label("On", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.green)
                    .transition(.scale.combined(with: .opacity))
            } else {
                Button(action: action) {
                    Label("Allow…", systemImage: "hand.raised").padding(.horizontal, 4)
                }
                .buttonStyle(.glassProminent)
                .tint(.orange)
            }
        }
        .padding(16)
        .glassEffect(granted ? .regular.tint(.green.opacity(0.18)) : .regular, in: .rect(cornerRadius: 22))
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: granted)
        .accessibilityElement(children: .combine)
    }

    // 3. Meet your buttons

    private var buttonsPage: some View {
        HStack(alignment: .center, spacing: 26) {
            TrackballView(pressed: model.pressed, ballSpeed: model.liveBallSpeed,
                          notchRate: model.liveNotchRate, ringAngle: model.ringAngle,
                          ballPhase: model.ballPhase)
                .frame(width: 230)
                .animation(.linear(duration: 1 / AppModel.sampleRate), value: model.ringAngle)

            VStack(alignment: .leading, spacing: 10) {
                header("hand.tap", "Meet your buttons", "Press each button on your trackball.")
                    .padding(.bottom, 4)
                ForEach(Self.buttons, id: \.index) { b in
                    buttonRow(b.index, b.name, b.normally)
                }
                buttonsFootnote
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
    }

    private func buttonRow(_ index: Int, _ name: String, _ normally: String) -> some View {
        let isPressed = model.pressed.contains(index)
        let isFound = found.contains(index)
        let action = model.config.buttons[index] ?? .system
        let does = index == 0 ? String(localized: "Left click — always") : action == .system ? normally : action.title
        return HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(isPressed ? Color.cyan : Color.white.opacity(0.12))
                    .shadow(color: isPressed ? .cyan : .clear, radius: 10)
                Text(verbatim: "\(index + 1)")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(isPressed ? .black : .primary)
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 14, weight: .semibold))
                Text("Does: \(does)").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: isFound ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 18))
                .foregroundStyle(isFound ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
                .contentTransition(.symbolEffect(.replace))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .glassEffect(isPressed ? .regular.tint(.cyan.opacity(0.25)) : .regular, in: .rect(cornerRadius: 18))
        .animation(.easeOut(duration: 0.12), value: isPressed)
        .accessibilityElement(children: .combine)
        .accessibilityValue(isFound ? "Found" : "Not pressed yet")
    }

    @ViewBuilder private var buttonsFootnote: some View {
        if !model.permissionsOK {
            Label("Glide can't see your buttons until both permissions are on. You can come back to this tour from Help.",
                  systemImage: "lock")
                .foregroundStyle(.orange)
        } else if !model.status.deviceConnected {
            if let name = model.status.unsupportedDeviceName {
                Label("Your \(name) works with Glide through the Beta program — you can turn it on at the end of the tour.",
                      systemImage: "flask")
                    .foregroundStyle(.secondary)
            } else {
                Label("Plug in your Expert Mouse to try this.", systemImage: "cable.connector")
                    .foregroundStyle(.secondary)
            }
        } else if found.count == 4 {
            Label("All four found. Change what they do any time in the Buttons tab.", systemImage: "sparkles")
                .foregroundStyle(.green)
        } else {
            Label("\(found.count) of 4 found. Shortcuts are paused while you try them, so nothing happens by surprise.",
                  systemImage: "hand.point.up.left")
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
        }
    }

    // 4. Scrolling and pointer speed

    private var scrollingPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            header("arrow.up.and.down.circle", "Choose your scrolling",
                   "How the scroll ring moves the page. Try one, spin the ring, and switch whenever you like.")
            ModePicker(mode: $model.config.scrollMode)
            VStack(alignment: .leading, spacing: 10) {
                Label("Pointer speed", systemImage: "cursorarrow.motionlines")
                    .font(.system(size: 14, weight: .semibold))
                Text("How far the cursor travels when you roll the ball. macOS stops at its own setting; Glide goes past it.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                PointerPresetRow(speed: $model.config.trackingSpeed)
            }
            .padding(.top, 6)
            Spacer(minLength: 0)
            Text("Fine-tune both later in the Pointer and Scrolling tabs.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
    }

    // 5. Safety

    private var safetyPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            header("checkmark.shield", "You're always in control",
                   "Two promises that keep your Mac usable, whatever you set up.")
            HStack(alignment: .top, spacing: 16) {
                safetyCard {
                    HStack(spacing: 6) {
                        ForEach(["⌃", "⌥", "⌘", "G"], id: \.self) { keycap($0) }
                    }
                    Text("Pause instantly").font(.system(size: 17, weight: .semibold))
                    Text("Press ⌃⌥⌘G anywhere and Glide pauses — your trackball goes straight back to plain macOS. Press it again to resume.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    StatusPill(text: model.config.enabled ? "Glide is on — try it" : "Glide is paused",
                               color: model.config.enabled ? .green : .gray)
                        .animation(.smooth, value: model.config.enabled)
                }
                safetyCard {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(width: 44, height: 44)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.cyan.opacity(0.85)))
                        .shadow(color: .cyan.opacity(0.6), radius: 10)
                    Text("Main click stays a left click").font(.system(size: 17, weight: .semibold))
                    Text("The bottom-left button is always a left click, whatever else you remap — so Glide can never lock you out.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            Text("Quitting Glide also puts your trackball back to normal.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
    }

    private func safetyCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) { content() }
            .padding(20)
            .frame(maxWidth: .infinity, minHeight: 210, alignment: .topLeading)
            .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }

    private func keycap(_ key: String) -> some View {
        Text(key)
            .font(.system(size: 17, weight: .semibold, design: .rounded))
            .frame(width: 40, height: 40)
            .glassEffect(.regular, in: .rect(cornerRadius: 10))
    }

    // 6. Done

    private var donePage: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 76))
                .foregroundStyle(.green.gradient)
                .shadow(color: .green.opacity(0.5), radius: 24)
                .symbolEffect(.bounce, options: .nonRepeating)
            Text("You're all set")
                .font(.system(size: 34, weight: .bold, design: .rounded))
            Text("Glide keeps running when you close its window — click Glide in the Dock to come back.")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button {
                    model.closeWelcomeTour()
                    model.showingFeedback = true
                } label: {
                    Label("Send Feedback…", systemImage: "paperplane").padding(.horizontal, 4)
                }
                Button {
                    NSWorkspace.shared.open(URL(string: "https://glide-trackball.netlify.app")!)
                } label: {
                    Label("Glide Website", systemImage: "safari").padding(.horizontal, 4)
                }
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .padding(.top, 4)
            if let name = model.status.unsupportedDeviceName, !model.betaProgram {
                HStack(spacing: 12) {
                    Image(systemName: "flask").foregroundStyle(.purple)
                    Text("Turn on the Beta program to try Glide with your \(name).")
                        .font(.system(size: 12))
                    Button("Turn On") { model.betaProgram = true }
                        .buttonStyle(.glass)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassEffect(.regular.tint(.purple.opacity(0.15)), in: .capsule)
                .padding(.top, 6)
            }
            Spacer(minLength: 0)
            Text("See this tour again any time from Help › Show Welcome Tour…")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }
}
