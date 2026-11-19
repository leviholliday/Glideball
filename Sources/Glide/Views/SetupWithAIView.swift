import AppKit
import SwiftUI

// "Set up with AI": one sheet over the window, three numbered steps. Copy a prompt, talk it
// through with whichever chatbot you use, paste back the setup code it wrote into the paste
// box (`PasteBox`, the same one Paste a Link… uses). Review Changes… swaps the sheet for the
// same preview a shared setup gets; only Apply there changes anything.
//
// Glideball sends nothing anywhere here: it copies text and reads what's pasted. The logic
// is in AppModel+AISetup.swift; what's in the sheet and its box lives on the model
// (`AISetupFlow`), so closing it and coming back from the chatbot finds it as it was.

extension SetupCode.Problem {
    /// Why the box's text can't be reviewed, in words the person can act on.
    var message: String {
        switch self {
        case .empty: String(localized: "Paste the setup code first.", comment: "Set up with AI: the box is empty")
        case .cutOff:
            String(localized: "That code is cut off before its end. Copy the whole block from the chatbot, from the first { to the last }.",
                   comment: "Set up with AI: a setup code that starts but never ends")
        case .notJSON:
            String(localized: "That doesn’t look like a whole setup code. Copy the whole block from the chatbot, from the first { to the last }.",
                   comment: "Set up with AI: what was pasted can't be read")
        case .tooBig, .tooDeep:
            String(localized: "That’s too long to be a setup code. Copy just the code block from the chatbot.", comment: "Set up with AI: what was pasted is far too big")
        case .notASetup:
            String(localized: "That’s not a Glideball setup code. Ask the chatbot for the setup code again.", comment: "Set up with AI: what was pasted is something else")
        case .newerVersion:
            String(localized: "That code is for a newer Glideball. Ask the chatbot for the code again, with \"version\": 1.",
                   comment: "Set up with AI: a setup code with a version this Glideball doesn't read")
        case .nothingUsable:
            String(localized: "Glideball couldn’t use anything in that code. Copy the note for the AI and paste it to the chatbot.",
                   comment: "Set up with AI: every part of a setup code was left out")
        }
    }
}

struct SetupWithAISheet: View {
    @Bindable var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var stepsHeight: CGFloat = 380

    static let width: CGFloat = 580
    /// The steps' most height before they scroll (the whole sheet stays about 700 pt).
    static let maxStepsHeight: CGFloat = 520

    private var flow: AISetupFlow { model.aiSetup }

    var body: some View {
        Group {
            if let incoming = flow.reviewing {
                IncomingSetupSheet(model: model, incoming: incoming,
                                   onCancel: { model.cancelAIReview() },
                                   onApply: { model.applyAIReview(parts: $0) })
                    .id(incoming.id)
                    .transition(.opacity)
            } else {
                steps
                    .transition(.opacity)
            }
        }
        .frame(width: Self.width)
        .animation(Theme.Motion.fade, value: flow.reviewing?.id)
    }

    private var steps: some View {
        let reading = model.aiReading(flow.text)
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Set up with AI")
                    .font(.system(size: 22, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("Talk it through with a chatbot and let it write your setup. It asks what you do on your Mac, suggests ideas for your buttons, and gives you a code to paste back here.")
                    .font(Theme.Font.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 20)

            // The steps scroll once "What's in it" and the prompt make them taller than a laptop's screen.
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    copyStep
                    talkStep
                    if flow.applied { appliedStep } else { pasteStep(reading) }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { stepsHeight = $0 }
            }
            .scrollIndicators(.automatic)
            .frame(height: min(stepsHeight, Self.maxStepsHeight))

            Hairline()
            footer
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
        }
        .background(GlideBackground(anchor: UnitPoint(x: 0.2, y: -0.1), strength: 0.7))
        .animation(reduceMotion ? Theme.Motion.fade : Theme.Motion.spring, value: flow.showingContents)
        .animation(reduceMotion ? Theme.Motion.fade : Theme.Motion.spring, value: flow.showingPrompt)
        .animation(Theme.Motion.fade, value: flow.applied)
    }

    // MARK: 1 Copy

    private var copyStep: some View {
        StepRow(number: 1, state: flow.step == 1 ? .current : .done) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Copy the prompt").font(Theme.Font.sectionTitle)
                    Text(flow.copied
                         ? "Copied. Paste it into ChatGPT, Claude, Gemini or whichever chatbot you use. It’s a few pages long, so give the chatbot a moment."
                         : "Then paste it into ChatGPT, Claude, Gemini or whichever chatbot you use.")
                        .font(Theme.Font.hint)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                let copy = CopyButton(id: "ai-prompt", title: Text("Copy Prompt"), help: Text("Copies the prompt to the clipboard. Glideball doesn’t send it anywhere."),
                                      copy: { model.copyAIPrompt() ? .copied(nil) : .failed })
                if flow.step == 1 {
                    copy.buttonStyle(.borderedProminent).tint(Theme.ball)
                } else {
                    copy.buttonStyle(.bordered)
                }
            }
            Button {
                flow.showingContents.toggle()
                if !flow.showingContents { flow.showingPrompt = false }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(flow.showingContents ? 90 : 0))
                    Text("What’s in it")
                }
                .font(Theme.Font.hint.weight(.medium))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
            .accessibilityValue(flow.showingContents ? Text("Open", comment: "Accessibility: a section that's shown") : Text("Closed", comment: "Accessibility: a section that's hidden"))
            if flow.showingContents { contents.transition(.opacity) }
        }
    }

    /// Exactly what the prompt holds and what it never does, and the prompt itself to read.
    private var contents: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                bullet("Your pointer and scroll settings")
                bullet("What each button, combo and gesture does, with any keyboard shortcuts on them")
                bullet("The apps you have app setups for and the apps your buttons open, by name")
                    .opacity(flow.leaveAppNamesOut ? 0.4 : 1)
                bullet("Your ball color’s name and your sound switches")
                bullet("Your trackball’s model, Glideball’s version and the language Glideball is in")
                bullet("What Glideball can change, and how to talk with you")
            }
            Toggle(isOn: Bindable(flow).leaveAppNamesOut) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Leave app names out").font(.system(size: 12))
                    Text("The chatbot can still set things up for an app if you tell it which.")
                        .font(Theme.Font.hint)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.checkbox)
            Text("Never in it: your name, your Mac’s or a display’s name, your own ball colors, per-display speeds, the apps a Switcher hides, Glideball’s own keyboard shortcuts, your stats, or anything about your files or what’s on screen.")
                .font(Theme.Font.hint)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Glideball doesn’t send this anywhere. It goes where you paste it, and that chatbot’s own privacy rules apply to it.")
                .font(Theme.Font.hint)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if AppLanguage.onScreen != .english {
                Text("The prompt is in English, because chatbots follow that best. It asks the chatbot to talk with you in \(AppLanguage.onScreen.nativeName).",
                     comment: "Set up with AI; %@ is a language's own name, like Deutsch")
                    .font(Theme.Font.hint)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.aiPromptIsLong {
                Text("Your setup makes this a long prompt. If the chatbot cuts it short, leave app names out and copy it again.")
                    .font(Theme.Font.hint)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(flow.showingPrompt ? "Hide the Prompt" : "Show the Prompt") { flow.showingPrompt.toggle() }
                .controlSize(.small)
            if flow.showingPrompt {
                ScrollView {
                    Text(verbatim: model.aiPrompt())
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(height: 170)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(Theme.well))
                .pixelBorder(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous), Theme.groupBorder)
                .transition(.opacity)
            }
        }
        .padding(.top, 4)
    }

    private func bullet(_ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Circle().fill(.tertiary).frame(width: 4, height: 4).offset(y: -2)
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: 2 Talk

    private var talkStep: some View {
        StepRow(number: 2, state: flow.step == 2 ? .current : flow.step > 2 ? .done : .waiting) {
            Text("Talk it through").font(Theme.Font.sectionTitle)
            Text("Talking works better than typing for this. Use the chatbot’s voice mode, or dictation like Wispr Flow, and just describe your day. It asks a few questions at a time and suggests ideas.")
                .font(Theme.Font.hint)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 3 Paste

    private func pasteStep(_ reading: ImportPaste.Reading) -> some View {
        let matches = model.readingMatches(reading)
        let reviewable = model.incoming(for: reading) != nil && !matches
        return StepRow(number: 3, state: flow.step == 3 ? .current : .waiting) {
            Text("Paste the code it gives you").font(Theme.Font.sectionTitle)
                .padding(.bottom, 4)
            PasteBox(text: Bindable(flow).text, reading: reading,
                     placeholder: "{\"format\": \"glideball-ai-setup\", …}",
                     emptyHint: "Copy the code block from the chatbot, then paste it here with ⌘V or Paste. Glideball only reads the clipboard when you do.",
                     describe: { model.readingMatches(.share($0, .json)) ? String(localized: "This matches what you have already.") : PasteBox.describe($0) },
                     describeCode: { r in
                         model.readingMatches(.code(r))
                             ? (r.notes.isEmpty ? String(localized: "This matches what you have already.")
                                 : String(localized: "What Glideball could use of this matches what you have already. The rest was left out.",
                                          comment: "Set up with AI: a setup code that changes nothing, with parts Glideball couldn't use"), false)
                             : (PasteBox.describe(code: r), true)
                     },
                     autofocus: flow.step == 3,
                     height: 96)
            HStack(alignment: .center, spacing: 10) {
                if let note = noteForAI(reading) {
                    CopyButton(id: "ai-note", title: Text("Copy Note for the AI"),
                               help: Text("Copies a short note to paste back to the chatbot, so it can fix the code"),
                               copy: { note() ? .copied(nil) : .failed })
                        .controlSize(.small)
                }
                Spacer(minLength: 0)
                Button {
                    model.reviewAICode()
                } label: {
                    Text("Review Changes…").frame(minWidth: 60)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.ball)
                .keyboardShortcut(.defaultAction)
                .disabled(!reviewable)
            }
            .padding(.top, 6)
        }
    }

    /// What Copy Note for the AI copies for this reading, if there's anything to tell the chatbot.
    private func noteForAI(_ reading: ImportPaste.Reading) -> (() -> Bool)? {
        switch reading {
        case .codeRefused(.empty): nil
        case .codeRefused(let p): { model.copyAINote(for: p) }
        case .code(let r) where !r.notes.isEmpty && model.readingMatches(reading): { model.copyAINote(r.notes) }
        default: nil
        }
    }

    private var appliedStep: some View {
        StepRow(number: 3, state: .done) {
            Text("Applied. Try it for a bit.").font(Theme.Font.sectionTitle)
            Text("Something not right? Tell the chatbot what felt wrong and paste the new code here. If you’ve changed things in Glideball since, give it your setup again first.")
                .font(Theme.Font.hint)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !flow.appliedLeftOut.isEmpty {
                Text("Some of that code was left out. The note tells the chatbot what to fix.")
                    .font(Theme.Font.hint)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                CopyButton(id: "ai-my-setup", title: Text("Copy My Setup"),
                           help: Text("Copies your setup as it is now, to paste into the same chat"),
                           copy: { model.copyAISetup() ? .copied(nil) : .failed })
                if !flow.appliedLeftOut.isEmpty {
                    CopyButton(id: "ai-applied-note", title: Text("Copy Note for the AI"),
                               copy: { model.copyAINote(flow.appliedLeftOut) ? .copied(nil) : .failed })
                }
                Spacer(minLength: 0)
                Button("Undo") { model.undoAISetup() }
                Button("Paste Another Code") {
                    flow.applied = false
                    flow.appliedLeftOut = []
                    flow.text = ""
                }
            }
            .controlSize(.small)
            .padding(.top, 6)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(alignment: .center, spacing: 12) {
            Label {
                Text("Glideball has no AI in it and sends nothing anywhere: it copies text and reads what you paste. A code can only change Glideball’s settings. Nothing runs on your Mac, and the bottom-left button always stays a left click.")
            } icon: {
                Image(systemName: "lock")
            }
            .font(Theme.Font.hint)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Done") { model.showingAISetup = false }
                .keyboardShortcut(.cancelAction)
                .controlSize(.large)
        }
    }
}

/// One numbered step: its marker, then whatever it holds.
private struct StepRow<Content: View>: View {
    enum Mark { case waiting, current, done }
    let number: Int
    let state: Mark
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(state == .current ? AnyShapeStyle(Theme.ball) : state == .done ? AnyShapeStyle(Theme.ball.opacity(0.16)) : AnyShapeStyle(Theme.groupFill))
                if state == .waiting { Circle().strokeBorder(Theme.groupBorder, lineWidth: 1) }
                if state == .done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.ball)
                } else {
                    Text(verbatim: "\(number)")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(state == .current ? AnyShapeStyle(Color.white) : AnyShapeStyle(.secondary))
                }
            }
            .frame(width: 22, height: 22)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .animation(Theme.Motion.fade, value: state)
        .accessibilityElement(children: .contain)
    }
}

extension Findable {
    static let setUpWithAI = Findable(
        id: "set-up-with-ai", title: String(localized: "Set up with AI"),
        detail: String(localized: "Talk your setup through with a chatbot, then paste back the code it writes. You see every change before it’s applied.", comment: "Search palette: Set up with AI"),
        keywords: String(localized: "ai, chatbot, chatgpt, claude, gemini, assistant, help me, set up, setup code, paste code, voice, dictation, ideas, suggestions", comment: "Search words for Set up with AI (comma-separated)"),
        symbol: "text.bubble", place: .tab(.buttons), part: .clicks)
}

/// The Buttons page's way in: one quiet row under the presets.
struct SetupWithAIRow: View {
    let model: AppModel

    var body: some View {
        RowGroup {
            ActionRow(title: "Set up with AI",
                      hint: "Not sure what to put on your buttons? Talk it through with a chatbot, then paste back the setup it writes.",
                      symbol: "text.bubble") { model.showAISetup() }
        }
    }
}
