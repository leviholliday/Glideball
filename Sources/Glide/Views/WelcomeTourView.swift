import AppKit
import SwiftUI

/// The first-launch walkthrough, over the whole window: hello, the two
/// permissions, meet your buttons, try the ring and pick a speed, done. About
/// a minute, and by the end the scroll ring has glided under your hand and the
/// pointer is set. Return / → go on, ← goes back, esc skips. Opened by
/// `AppModel.showingWelcomeTour`; closing it shows the real window underneath.
struct WelcomeTourView: View {
    @Bindable var model: AppModel

    enum Step: Int, CaseIterable, Identifiable {
        case welcome, permissions, buttons, tryIt, done
        var id: Int { rawValue }
        /// For `--render-ui`'s file names.
        var name: String {
            switch self {
            case .welcome: "welcome"
            case .permissions: "permissions"
            case .buttons: "buttons"
            case .tryIt: "scroll-and-speed"
            case .done: "done"
            }
        }
    }

    @State private var step: Step
    @State private var forward = true
    @State private var found: Set<Int>
    /// The first button found: its check bounces, once (the tour's "it works").
    @State private var firstFound: Int?
    @FocusState private var focused: Bool
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `step` other than `.welcome` (and `found`) are for `--render-ui` and `--self-test`, which draw every step.
    init(model: AppModel, step: Step = .welcome, found: Set<Int> = []) {
        self.model = model
        _step = State(initialValue: step)
        _found = State(initialValue: found)
        _firstFound = State(initialValue: found.min())
    }

    private static let buttons: [(index: Int, name: String, normally: String)] = [2, 3, 0, 1].map {
        ($0, AppModel.buttonName($0), AppModel.buttonDefault($0))
    }

    var body: some View {
        ZStack {
            GlideBackground()
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button("Skip Tour", action: model.closeWelcomeTour)
                        .buttonStyle(HoverButtonStyle(radius: 6))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .keyboardShortcut(.cancelAction)
                        .help("Close the tour (esc). Reopen it from Help › Show Welcome Tour…")
                        .opacity(step == .done ? 0 : 1)
                }
                .padding(.horizontal, 22)
                .padding(.top, 16)

                ZStack {
                    page(step)
                        .id(step)
                        .transition(pageTransition)
                }
                .frame(maxWidth: 820, maxHeight: .infinity)
                .padding(.horizontal, 48)

                footer
                    .frame(maxWidth: 820)
                    .padding(.horizontal, 48)
                    .padding(.top, 12)
                    .padding(.bottom, 26)
            }
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
            guard !new.isEmpty else { return }
            if firstFound == nil { firstFound = new.min() }
            withAnimation(Theme.Motion.spring) { found.formUnion(new) }
        }
    }

    private var pageTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(insertion: .opacity.combined(with: .offset(x: forward ? 18 : -18)),
                           removal: .opacity)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if step != .welcome {
                Button(action: back) {
                    Label("Back", systemImage: "chevron.left").padding(.horizontal, 2)
                }
                .controlSize(.large)
            }
            Spacer()
            if step == .permissions && !model.permissionsOK {
                Button("Skip for now") { advance(force: true) }
                    .buttonStyle(HoverButtonStyle(radius: 6))
                    .foregroundStyle(.secondary)
                    .help("Glideball stays out of the way until both permissions are on")
            }
            Button(action: { advance() }) {
                Text(nextTitle).padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.ball)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(!canAdvance)
        }
        .overlay { dots }
    }

    private var dots: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases) { s in
                Capsule()
                    .fill(Color.primary.opacity(s == step ? 0.7 : 0.18))
                    .frame(width: s == step ? 18 : 6, height: 6)
            }
        }
        .animation(Theme.Motion.spring, value: step)
        .accessibilityElement()
        .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count)")
    }

    private var nextTitle: String {
        switch step {
        case .welcome: String(localized: "Get Started")
        case .done: String(localized: "Start Using Glideball")
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

    /// Sets the direction first, so the page leaving goes the right way too.
    private func go(to target: Step, forward: Bool) {
        self.forward = forward
        DispatchQueue.main.async {
            withAnimation(reduceMotion ? Theme.Motion.fade : .easeOut(duration: 0.22)) { step = target }
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
        case .tryIt: tryItPage
        case .done: donePage
        }
    }

    private func header(_ title: LocalizedStringKey, _ subtitle: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(Theme.Font.pageTitle)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .font(Theme.Font.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The live trackball on its dark stage, like the sidebar's.
    private func stage(_ side: CGFloat, look: TrackballLook) -> some View {
        TrackballView(feed: model.live, pressed: model.pressed, look: look)
            .frame(width: side, height: side)
            .padding(side * 0.09)
            .background(RoundedRectangle(cornerRadius: side * 0.13, style: .continuous).fill(Theme.stage))
            .overlay(RoundedRectangle(cornerRadius: side * 0.13, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5))
    }

    // 1. Welcome

    private var welcomePage: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            stage(180, look: .connected)
            Text("Welcome to Glideball")
                .font(.system(size: 30, weight: .semibold))
                .padding(.top, 28)
            Text("Let’s set up your trackball. It takes about a minute.")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
            Spacer(minLength: 0)
            Text("Press Return to go on, or use the arrow keys.")
                .font(Theme.Font.hint)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }

    // 2. Permissions

    private var permissionsPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            Spacer(minLength: 0)
            header("Two quick permissions",
                   "Glideball needs these to read your trackball and change what it does. Until both are on, your trackball works normally and Glideball stays out of the way.")
            RowGroup(dividerInset: Theme.Space.rowHorizontal + Theme.Space.symbolColumn + Theme.Space.symbolGap) {
                permissionRow("Accessibility", symbol: "accessibility",
                              detail: "Lets Glideball change what your buttons and scroll ring do.",
                              granted: model.hasAccessibility, action: model.requestAccessibility)
                permissionRow("Input Monitoring", symbol: "keyboard.badge.eye",
                              detail: "Lets Glideball tell your trackball apart from your other mice and trackpad.",
                              granted: model.hasInputMonitoring, action: model.requestInputMonitoring)
            }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Group {
                    if model.permissionsOK {
                        Label("All set. Glideball can see your trackball.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Theme.ok)
                    } else {
                        Label("Switch Glideball on in each list in System Settings, then come back. The checkmarks update by themselves.",
                              systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Link("Why?", destination: SiteLinks.permissions)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.ball)
                    .help("How Glideball uses these, on the Glideball website")
            }
            .animation(Theme.Motion.spring, value: model.permissionsOK)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: 580)
        .frame(maxWidth: .infinity)
    }

    private func permissionRow(_ name: LocalizedStringKey, symbol: String, detail: LocalizedStringKey, granted: Bool,
                               action: @escaping () -> Void) -> some View {
        HStack(spacing: Theme.Space.symbolGap) {
            Image(systemName: granted ? "checkmark.circle.fill" : symbol)
                .font(.system(size: 16))
                .foregroundStyle(granted ? AnyShapeStyle(Theme.ok) : AnyShapeStyle(.secondary))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: Theme.Space.symbolColumn)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 13, weight: .semibold))
                Text(detail).font(Theme.Font.hint).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if granted {
                Text("On")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.ok)
                    .transition(.opacity)
            } else {
                Button("Allow…", action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.ball)
            }
        }
        .padding(.horizontal, Theme.Space.rowHorizontal)
        .padding(.vertical, 12)
        .frame(minHeight: 56)
        .background(Theme.ok.opacity(granted ? 0.08 : 0))
        .animation(Theme.Motion.spring, value: granted)
        .accessibilityElement(children: .combine)
    }

    // 3. Meet your buttons

    private var buttonsPage: some View {
        HStack(alignment: .center, spacing: 40) {
            stage(220, look: TrackballLook.of(model))
            VStack(alignment: .leading, spacing: 18) {
                header("Meet your buttons", "Press each button on your trackball.")
                RowGroup(dividerInset: Theme.Space.rowHorizontal + Theme.Space.symbolColumn + Theme.Space.symbolGap) {
                    ForEach(Self.buttons, id: \.index) { b in
                        buttonRow(b.index, b.name, b.normally)
                    }
                }
                buttonsFootnote
                    .font(.system(size: 12, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func buttonRow(_ index: Int, _ name: String, _ normally: String) -> some View {
        let isPressed = model.pressed.contains(index)
        let isFound = found.contains(index)
        let action = model.config.buttons[index] ?? .system
        let does = index == 0 ? String(localized: "Left click, always") : action == .system ? normally : action.title
        return HStack(spacing: Theme.Space.symbolGap) {
            CornerGlyph(index: index, lit: isPressed)
                .frame(width: Theme.Space.symbolColumn)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 13, weight: .medium))
                Text("Does: \(does)").font(Theme.Font.hint).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: isFound ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 17))
                .foregroundStyle(isFound ? AnyShapeStyle(Theme.ok) : AnyShapeStyle(.tertiary))
                .contentTransition(.symbolEffect(.replace))
                // The tour's one bounce: the very first button found.
                .symbolEffect(.bounce, options: .nonRepeating, value: !reduceMotion && firstFound == index)
        }
        .padding(.horizontal, Theme.Space.rowHorizontal)
        .padding(.vertical, 10)
        .frame(minHeight: Theme.Space.rowMinHeight)
        .background(Theme.buttons.opacity(isPressed ? 0.16 : 0))
        .animation(isPressed ? Theme.Motion.pressIn : Theme.Motion.pressOut, value: isPressed)
        .accessibilityElement(children: .combine)
        .accessibilityValue(isFound ? "Found" : "Not pressed yet")
    }

    @ViewBuilder private var buttonsFootnote: some View {
        if !model.permissionsOK {
            Label("Glideball can't see your buttons until both permissions are on. You can come back to this tour from Help.",
                  systemImage: "lock")
                .foregroundStyle(Theme.warn)
        } else if !model.status.deviceConnected {
            if let name = model.status.unsupportedDeviceName {
                Label("Your \(name) can work with Glideball if you turn on Other Kensington trackballs. You can do that at the end of the tour.",
                      systemImage: "computermouse")
                    .foregroundStyle(.secondary)
            } else {
                Label("Plug in your Expert Mouse to try this.", systemImage: "cable.connector")
                    .foregroundStyle(.secondary)
            }
        } else if found.count == 4 {
            Label("All four found. Change what they do any time in the Buttons tab.", systemImage: "checkmark.circle")
                .foregroundStyle(Theme.ok)
        } else if !found.isEmpty {
            Label("It works. \(found.count) of 4 found.", systemImage: "hand.point.up.left")
                .foregroundStyle(.primary)
                .contentTransition(.numericText())
        } else {
            Label("\(found.count) of 4 found. Shortcuts are paused while you try them, so nothing happens by surprise.",
                  systemImage: "hand.point.up.left")
                .foregroundStyle(.secondary)
        }
    }

    // 4. Try the ring, pick a speed

    private var tryItPage: some View {
        HStack(alignment: .top, spacing: 36) {
            VStack(alignment: .leading, spacing: 14) {
                header("Spin the scroll ring", "Give it a flick over the ruler and watch how far it glides.")
                Picker("Scrolling", selection: $model.config.scrollMode) {
                    ForEach(ScrollMode.allCases) { m in Text(m.title).tag(m) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(modeHint)
                    .font(Theme.Font.hint)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                ScrollRuler()
                    .frame(maxHeight: .infinity)
                    .groupBackground()
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 14) {
                header("Pick a pointer speed", "Roll the ball after each one to feel the difference.")
                PointerPresetRow(speed: $model.config.trackingSpeed)
                Text("How far the cursor travels when you roll the ball. macOS stops at its own setting; Glideball goes past it.")
                    .font(Theme.Font.hint)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                // The ball and ring answer as you try them.
                stage(150, look: TrackballLook.of(model))
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
                Text("Fine-tune both later in the Pointer and Scrolling tabs.")
                    .font(Theme.Font.hint)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.top, 8)
    }

    private var modeHint: String {
        switch model.config.scrollMode {
        case .native: String(localized: "macOS does the scrolling")
        case .flywheel: String(localized: "Push and glide (Kensington's feel)")
        case .follow: String(localized: "Page tracks the ring exactly")
        }
    }

    // 5. Done

    private var donePage: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(Theme.ok)
            Text("You’re all set")
                .font(.system(size: 30, weight: .semibold))
                .padding(.top, 16)
            RowGroup {
                SettingRow(title: "Pause any time with \(pauseShortcut)",
                           hint: "Your trackball goes straight back to plain macOS. Press it again to resume.",
                           symbol: "pause.circle")
                SettingRow(title: "Closing the window keeps Glideball running",
                           hint: "Open it again from the Dock or the menu bar.",
                           symbol: "macwindow")
                if let name = model.status.unsupportedDeviceName, !model.otherTrackballs {
                    SettingRow(title: "Turn on Other Kensington trackballs to try Glideball with your \(name).",
                               symbol: "computermouse") {
                        Button("Turn On") { model.otherTrackballs = true }
                            .controlSize(.small)
                    }
                }
            }
            .frame(maxWidth: 480)
            .padding(.top, 26)
            Spacer(minLength: 0)
            Text("See this tour again any time from Help › Show Welcome Tour…")
                .font(Theme.Font.hint)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }

    private var pauseShortcut: String {
        model.config.globalShortcuts.pause?.display ?? "⌃⌥⌘G"
    }
}

/// Something to scroll in the tour: a ruler, numbered every ten lines, with
/// the ring's pink on the long marks. Flick the ring and see how far it goes.
private struct ScrollRuler: View {
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(0..<600, id: \.self) { i in
                    HStack(spacing: 8) {
                        Rectangle()
                            .fill(i % 10 == 0 ? AnyShapeStyle(Theme.ring) : AnyShapeStyle(Theme.hairline))
                            .frame(width: i % 10 == 0 ? 28 : i % 5 == 0 ? 18 : 10, height: i % 10 == 0 ? 1.5 : 1)
                        if i % 10 == 0 {
                            Text(verbatim: i.formatted())
                                .font(.system(size: 11, weight: .medium).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(height: 9, alignment: .leading)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .scrollIndicators(.automatic)
        .accessibilityLabel("A ruler to try scrolling on")
    }
}
