import AppKit
import SwiftUI

/// `--render-ui` screens for pasting a shared link (PasteViews.swift) and the copy
/// beat (CopyBeat.swift), frozen at moments of its motion.
extension RenderUI {
    static func pasteScreens(_ model: AppModel) -> [Screen] {
        var list: [Screen] = []
        func add(_ name: String, _ title: String, prepare: @escaping () -> Void = {}, cleanup: @escaping () -> Void = {},
                 draw: @escaping (Bool, CGFloat) -> NSBitmapImageRep?) {
            list.append(Screen(name: name, group: "Pasting a link and copying", title: title, prepare: prepare, draw: draw,
                               cleanup: {
                                   cleanup()
                                   CopyBeat.sandboxTime = nil
                                   CopyBeat.sandboxClicked = []
                                   resetSharing(model)
                                   baseline(model)
                               }))
        }

        // A friend's scroll feel, as a link.
        var friend = DemoData.config
        friend.scrollMode = .follow
        friend.scrollDistance = 22
        let link = { SharedSetup.make([.scrolling, .buttons], from: friend, look: nil, sounds: nil, name: "Sam")?.link()?.absoluteString ?? "" }
        func box(_ text: @escaping () -> String) -> (Bool, CGFloat) -> NSBitmapImageRep? {
            { dark, scale in sheet(PasteLinkSheet(model: model, request: PasteBoxRequest(text: text())), dark: dark, scale: scale) }
        }

        add("paste-box-empty", "Paste a Link…: the box, empty (the clipboard isn't read until Paste or ⌘V)", draw: box { "" })
        add("paste-box-valid", "Paste a Link…: a message with a link in it, read and ready to review",
            draw: box { "Try my scroll feel, it’s so smooth: \(link()) 🙂" })
        add("paste-box-wrong-host", "Paste a Link…: the same payload on another site, refused",
            draw: box { link().replacingOccurrences(of: "glideball.netlify.app/", with: "glideball.netlify.app.evil.com/") })
        add("paste-box-damaged", "Paste a Link…: a link cut off part-way", draw: box { String(link().dropLast(40)) })
        add("paste-box-command", "Paste a Link…: a glideball:// command link (never run from a paste)", draw: box { "glideball://pause" })
        add("paste-import-menu", "A page header's Import menu beside Share (drawn open; real menus can't be drawn)") { dark, scale in
            card(ImportMenuMock(model: model), width: 720, dark: dark, scale: scale)
        }
        add("sync-import-paste", "Sync's Import section with Paste a Link…") { dark, scale in
            fullPage(page(.backup, model), dark: dark, scale: scale)
        }

        // The copy beat, frozen. Times are seconds after the click.
        let panelTimes: [Double] = [0.03, 0.10, 0.17, 0.24, 0.30, 0.36, 0.55, 1.2]
        for t in panelTimes {
            add("copy-beat-picture-\(Int(t * 1000))", "Share…'s picture Copy, \(Int(t * 1000)) ms after the click",
                prepare: {
                    SharePanel.sandboxImage = ShareImage.render(.overview, delight: model.delight)
                    CopyBeat.sandboxTime = t
                    CopyBeat.sandboxClicked = ["copy"]
                },
                cleanup: { SharePanel.sandboxImage = nil }) { dark, scale in
                card(PopoverMock { SharePanel(card: .overview) }, width: 500, dark: dark, scale: scale)
            }
        }
        add("copy-beat-post-x", "Post on X: the picture copied, flying into the X button (180 ms)",
            prepare: {
                SharePanel.sandboxImage = ShareImage.render(.overview, delight: model.delight)
                CopyBeat.sandboxTime = 0.18
                CopyBeat.sandboxClicked = ["site-x"]
            },
            cleanup: { SharePanel.sandboxImage = nil }) { dark, scale in
            card(PopoverMock { SharePanel(card: .overview) }, width: 500, dark: dark, scale: scale)
        }
        for t in [0.08, 0.16, 0.24, 0.32, 1.2] {
            add("copy-beat-link-\(Int(t * 1000))", "Share…'s Copy Link, \(Int(t * 1000)) ms after the click",
                prepare: {
                    CopyBeat.sandboxTime = t
                    CopyBeat.sandboxClicked = ["link"]
                }) { dark, scale in
                sheet(ShareSetupSheet(model: model, request: ShareRequest(kind: .scrolling)), dark: dark, scale: scale)
            }
        }
        add("copy-beat-sheet-picture", "Share…'s picture Copy in the checklist sheet (170 ms)",
            prepare: {
                CopyBeat.sandboxTime = 0.17
                CopyBeat.sandboxClicked = ["picture"]
            }) { dark, scale in
            sheet(ShareSetupSheet(model: model, request: ShareRequest(kind: .scrolling)), dark: dark, scale: scale)
        }
        add("copy-beat-chip", "A Copy chip (Settings › Trackball's connection details) at its pop (330 ms)",
            prepare: {
                CopyBeat.sandboxTime = 0.33
                CopyBeat.sandboxClicked = ["connection-details"]
            }) { dark, scale in
            settings(.trackball, dark: dark, scale: scale)
        }
        return list
    }

    /// The Pointer page's header with the Import menu drawn open under it.
    struct ImportMenuMock: View {
        let model: AppModel
        var body: some View {
            VStack(alignment: .trailing, spacing: 6) {
                PageHeader(title: .verbatim(GlideTab.pointer.title), subtitle: .verbatim(GlideTab.pointer.summary)) {
                    HStack(spacing: 6) {
                        PageImportMenu(model: model)
                        PageShareMenu(tab: .pointer, model: model)
                    }
                }
                PopoverMock {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array([String(localized: "Paste a Link…", comment: "File menu and the Import menu: opens the box a shared link is pasted into"),
                                       String(localized: "Import a File…"), "",
                                       String(localized: "Set Up with AI…", comment: "File menu and the Import menu: opens Set up with AI (copy a prompt for a chatbot, paste back its setup code)")]
                                .enumerated()), id: \.offset) { i, title in
                            if title.isEmpty {
                                Divider().padding(.vertical, 3).frame(width: 200)
                            } else {
                                Text(verbatim: title)
                                    .font(.system(size: 13))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .frame(width: 200, alignment: .leading)
                                    .background(i == 0 ? RoundedRectangle(cornerRadius: 5).fill(Theme.ball) : nil)
                                    .foregroundStyle(i == 0 ? Color.white : Color.primary)
                            }
                        }
                    }
                    .padding(5)
                }
                .padding(.trailing, 70)
            }
            .frame(width: Theme.Space.contentMaxWidth - 40)
        }
    }
}
