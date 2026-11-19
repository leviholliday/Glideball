import AppKit
import SwiftUI

/// `--render-ui` screens for Set up with AI (Views/SetupWithAIView.swift): each step of the
/// sheet, what the box says about what's pasted, the preview inside the sheet, and a code
/// in Paste a Link…. Apps are the sandbox's fixed list (`InstalledApps.sandbox`).
extension RenderUI {
    static func aiSetupScreens(_ model: AppModel) -> [Screen] {
        var list: [Screen] = []
        let flow = model.aiSetup
        func add(_ name: String, _ title: String, prepare: @escaping () -> Void = {}, draw: ((Bool, CGFloat) -> NSBitmapImageRep?)? = nil) {
            list.append(Screen(name: name, group: "Set up with AI", title: title, prepare: {
                flow.reset()
                prepare()
            }, draw: draw ?? { dark, scale in sheet(SetupWithAISheet(model: model), dark: dark, scale: scale) },
            cleanup: {
                flow.reset()
                CopyBeat.sandboxTime = nil
                CopyBeat.sandboxClicked = []
                resetSharing(model)
                baseline(model)
            }))
        }

        let good = """
        Here’s what this changes: the top left button closes the tab you're on, and pressing both \
        bottom buttons together opens Notes.

        ```json
        {"format": "glideball-ai-setup", "version": 1, "trackingSpeed": 7,
         "buttons": {"2": "keys:cmd+w"},
         "combos": [{"buttons": [0, 1], "action": "open:Notes"}]}
        ```

        Copy the code, go back to Glideball and paste it.
        """
        let mistakes = """
        ```json
        {"format": "glideball-ai-setup", "version": 1, "trackingSpeed": 7,
         "buttons": {"0": "rightClick", "1": "macro:paste twice", "2": "open:Figmaa", "3": "keys:cmd+w"}}
        ```
        """
        let cutOff = """
        ```json
        {"format": "glideball-ai-setup", "version": 1,
         "buttons": {"2": "keys:cmd+w", "3": {"gesture": {"left": "keys:ctrl+left", "right": "keys:ctr
        """

        add("ai-setup-start", "Set up with AI, as it opens (step 1)")
        add("ai-setup-whats-in-it", "What's in it, open", prepare: { flow.showingContents = true })
        add("ai-setup-show-prompt", "What's in it with the prompt shown", prepare: {
            flow.showingContents = true
            flow.showingPrompt = true
        })
        add("ai-setup-app-names-out", "Leave app names out, ticked", prepare: {
            flow.showingContents = true
            flow.leaveAppNamesOut = true
        })
        add("ai-setup-copied", "Copy Prompt just clicked: step 2 lit", prepare: {
            flow.copied = true
            CopyBeat.sandboxTime = 1.0
            CopyBeat.sandboxClicked = ["ai-prompt"]
        })
        add("ai-setup-code", "A chatbot's whole answer pasted: the code in it read and ready to review", prepare: {
            flow.copied = true
            flow.text = good
        })
        add("ai-setup-code-left-out", "A code with mistakes: what's usable is ready, the rest will be listed", prepare: {
            flow.copied = true
            flow.text = mistakes
        })
        add("ai-setup-cut-off", "A code cut off part-way, with Copy Note for the AI", prepare: {
            flow.copied = true
            flow.text = cutOff
        })
        add("ai-setup-not-a-code", "Prose with no code in it", prepare: {
            flow.copied = true
            flow.text = "Sure! I’ve set your pointer speed to 6 and made the top left button close tabs."
        })
        add("ai-setup-matches", "Your own setup pasted back: nothing would change", prepare: {
            flow.copied = true
            flow.text = model.aiSetupCode()
        })
        add("ai-setup-review", "Review Changes…: the usual preview, inside the sheet, with Left out", prepare: {
            flow.copied = true
            flow.text = mistakes
            model.reviewAICode()
        })
        add("ai-setup-applied", "Applied: Copy My Setup, the note, Undo", prepare: {
            flow.copied = true
            flow.text = mistakes
            if case .code(let r) = model.aiReading(mistakes) {
                flow.applied = true
                flow.appliedLeftOut = r.notes
            }
        })
        add("ai-setup-paste-a-link", "Paste a Link… with a setup code in it", draw: { dark, scale in
            sheet(PasteLinkSheet(model: model, request: PasteBoxRequest(text: good)), dark: dark, scale: scale)
        })
        return list
    }
}
