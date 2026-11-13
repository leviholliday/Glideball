import AppKit
import SwiftUI

/// `--render-ui` screens for sharing a setup and importing from KensingtonWorks
/// (kept apart from RenderScreens.swift; `all` appends them).
extension RenderUI {
    static func sharingScreens(_ model: AppModel) -> [Screen] {
        var list: [Screen] = []
        func add(_ name: String, _ title: String, prepare: @escaping () -> Void = {}, cleanup: @escaping () -> Void = {},
                 draw: @escaping (Bool, CGFloat) -> NSBitmapImageRep?) {
            list.append(Screen(name: name, group: "Sharing a setup", title: title, prepare: prepare, draw: draw,
                               cleanup: { cleanup(); resetSharing(model); baseline(model) }))
        }
        func preview(_ incoming: @escaping () -> IncomingSetup?) -> (Bool, CGFloat) -> NSBitmapImageRep? {
            { dark, scale in
                guard let i = incoming() else { return nil }
                return sheet(IncomingSetupSheet(model: model, incoming: i), dark: dark, scale: scale)
            }
        }

        // What a friend's setup looks like coming in.
        var friend = DemoData.config
        friend.scrollMode = .follow
        friend.scrollDistance = 22
        friend.throwAmount = 0.7
        friend.trackingSpeed = 9.5
        friend.buttons[2] = .shortcut(.copy)
        friend.buttons[3] = .gesture(.media)
        friend.chords = [Chord(buttons: [2, 3], action: .openApp(bundleID: "com.apple.Notes"))]

        add("share-preview-link", "A link to a scroll feel: the preview, nothing changed yet",
            draw: preview { SharedSetup.make(.scrolling, from: friend, look: nil).map { IncomingSetup(source: .link, content: .shared($0)) } })
        add("share-preview-file", "A shared file with everything in it (with an Open and shortcuts to check)",
            draw: preview {
                SharedSetup.make(.everything, from: friend, look: ShareLook(theme: "sunset", custom: nil))
                    .map { IncomingSetup(source: .file("Sam’s Glideball setup"), content: .shared($0)) }
            })
        add("share-preview-app-setup", "A link to one app's setup (Xcode), new on this Mac",
            draw: preview {
                var c = friend
                var xcode = AppProfile(bundleID: "com.apple.dt.Xcode", name: "Xcode")
                xcode.trackingSpeed = 3.5
                xcode.buttons = [2: .shortcut(KeyShortcut.make(15, "R", .maskCommand)), 3: .openApp(bundleID: "com.apple.Terminal")]
                c.appProfiles = [xcode]
                return SharedSetup.make(.appSetup, from: c, look: nil, appSetup: "com.apple.dt.Xcode").map { IncomingSetup(source: .link, content: .shared($0)) }
            })
        add("share-preview-buttons", "A link to buttons and gestures",
            draw: preview { SharedSetup.make(.buttons, from: friend, look: nil).map { IncomingSetup(source: .link, content: .shared($0)) } })
        add("share-preview-nothing", "A link to settings you already have",
            draw: preview { SharedSetup.make(.pointer, from: model.config, look: nil).map { IncomingSetup(source: .link, content: .shared($0)) } })
        add("share-preview-kensingtonworks", "Importing KensingtonWorks' settings: what maps, and what has no equivalent",
            draw: preview {
                guard case .success(let s) = KensingtonWorks.parse(Data(KensingtonWorksSource.sample.utf8)),
                      let imp = KensingtonWorksImport.make(from: s) else { return nil }
                return IncomingSetup(source: .kensingtonWorks, content: .kensingtonWorks(imp))
            })

        // A checklist share from someone who put their name on it, with two parts left out.
        add("share-preview-parts", "A link with several parts and the sender's name; Combos and the ball color unticked",
            draw: { dark, scale in
                var them = friend
                var safari = AppProfile(bundleID: "com.apple.Safari", name: "Safari")
                safari.trackingSpeed = 6
                safari.buttons = [2: .back, 3: .forward]
                them.appProfiles = [safari]
                guard let s = SharedSetup.make([.pointer, .scrolling, .buttons, .combos, .app("com.apple.Safari"), .look, .sounds], from: them,
                                               look: ShareLook(theme: "ember", custom: nil),
                                               sounds: ShareSounds(on: true, volume: 0.5, kinds: ["ticks": false]), name: "Sam")
                else { return nil }
                let i = IncomingSetup(source: .link, content: .shared(s))
                return sheet(IncomingSetupSheet(model: model, incoming: i, chosen: Set(s.parts).subtracting([.combos, .look])), dark: dark, scale: scale)
            })
        add("share-preview-beta12", "A beta 12 link (one kind), read as its parts") { dark, scale in
            // {"format":"glideball-share","version":1,"kind":"pointer","trackingSpeed":12,"precisionSpeed":0.5}
            let json = #"{"format":"glideball-share","version":1,"kind":"pointer","trackingSpeed":12,"precisionSpeed":0.5,"writtenBy":"2.10-beta.12"}"#
            guard let packed = SharedSetup.deflate(Data(json.utf8)),
                  let s = try? SharedSetup.decode(linkPayload: SharedSetup.base64url(packed)) else { return nil }
            return sheet(IncomingSetupSheet(model: model, incoming: IncomingSetup(source: .link, content: .shared(s))), dark: dark, scale: scale)
        }

        // Sending.
        add("share-sheet-checklist", "Share… from Share Everything: the checklist, everything but per-display speeds ticked") { dark, scale in
            sheet(ShareSetupSheet(model: model, request: ShareRequest(kind: .everything)), dark: dark, scale: scale)
        }
        add("share-sheet-some", "Share…: pointer, buttons and one app setup ticked, with a name going with it",
            prepare: { useSharingName("Levi") }) { dark, scale in
            let first = model.config.appProfiles.first.map { SharePart.app($0.bundleID) }
            return sheet(ShareSetupSheet(model: model, request: ShareRequest(kind: .everything),
                                         chosen: Set([.pointer, .buttons, .gestures] + (first.map { [$0] } ?? []))), dark: dark, scale: scale)
        }
        add("share-sheet-none", "Share… with nothing ticked") { dark, scale in
            sheet(ShareSetupSheet(model: model, request: ShareRequest(kind: .everything), chosen: []), dark: dark, scale: scale)
        }
        for named in [false, true] {
            let suffix = named ? "-named" : ""
            let note = named ? " with a name on it" : " without a name"
            add("share-card-checklist\(suffix)", "The picture of a share of several parts\(note)",
                prepare: { if named { useSharingName("Levi") } }) { _, _ in
                let parts: Set<SharePart> = [.pointer, .scrolling, .buttons]
                let link = model.share(parts: parts)?.link()?.absoluteString
                return ShareImage.render(.setup(model.setupCard(parts: parts, link: link)), delight: model.delight)
            }
        }
        // Without a name these are RenderScreens' share-card-overview and share-card-badge.
        add("share-card-overview-named", "Overview's share picture with a name on it",
            prepare: { useSharingName("Levi") }) { _, _ in
            ShareImage.render(.overview, delight: model.delight)
        }
        add("share-card-badge-named", "A badge's share picture with a name on it",
            prepare: { useSharingName("Levi") }) { _, _ in
            guard let m = Milestone.all.first(where: { model.delight.ledger.earned[$0.id] != nil }) ?? Milestone.all.first else { return nil }
            return ShareImage.render(.badge(m, model.delight.ledger.earned[m.id] ?? Date()), delight: model.delight)
        }
        add("settings-sharing-named", "Settings › Sharing with a name typed",
            prepare: { useSharingName("Levi") }) { dark, scale in
            settings(.sharing, dark: dark, scale: scale)
        }
        add("tour-name-filled", "The tour's name step with a name typed",
            prepare: { useSharingName("Levi") }) { dark, scale in
            mainWindow(model, tab: .overview, dark: dark, scale: scale) {
                WelcomeTourView(model: model, step: .name)
            }
        }
        add("share-sheet", "Share…: pick a part, then a link, a file or a picture",
            prepare: { ShareSetupSheet.sandboxDone = String(localized: "Link copied. Paste it anywhere.") }) { dark, scale in
            sheet(ShareSetupSheet(model: model, request: ShareRequest(kind: .scrolling)), dark: dark, scale: scale)
        }
        add("share-sheet-app-setup", "Share… from an app setup on the Apps page") { dark, scale in
            sheet(ShareSetupSheet(model: model, request: ShareRequest(kind: .appSetup, appSetup: "com.apple.Safari", canChoose: false)),
                  dark: dark, scale: scale)
        }
        add("share-card-setup", "The share picture of a setup, with a QR code of its link (as saved, 2x)") { _, _ in
            let link = model.share(.scrolling)?.link()?.absoluteString
            return ShareImage.render(.setup(model.setupCard(.scrolling, link: link)), delight: model.delight)
        }
        add("share-card-setup-everything", "The share picture of everything (too big for a link: no QR code)") { _, _ in
            ShareImage.render(.setup(model.setupCard(.everything, link: nil)), delight: model.delight)
        }
        add("share-menu", "A page header's share menu (drawn open beside the header; real menus can't be drawn)") { dark, scale in
            card(ShareMenuMock(model: model), width: 720, dark: dark, scale: scale)
        }
        add("share-toast-applied", "Applied a shared setup: the toast with Undo",
            prepare: {
                model.show(.init(symbol: "arrow.down.doc.fill", text: String(localized: "Applied “\(String(localized: "A shared scroll feel", comment: "Import preview title"))”", comment: "Toast; the name of a button preset"),
                                 action: .undoImport))
            }) { dark, scale in
            mainWindow(model, tab: .scroll, dark: dark, scale: scale)
        }

        // KensingtonWorks found on this Mac.
        add("sync-kensingtonworks", "Sync, whole page, with KensingtonWorks settings found",
            prepare: { useSampleKensingtonWorks() }) { dark, scale in
            fullPage(page(.backup, model), dark: dark, scale: scale)
        }
        add("tour-6-done-kensingtonworks", "The tour's last step with KensingtonWorks settings found",
            prepare: { useSampleKensingtonWorks() }) { dark, scale in
            mainWindow(model, tab: .overview, dark: dark, scale: scale) {
                WelcomeTourView(model: model, step: .done)
            }
        }
        return list
    }

    static func useSampleKensingtonWorks() {
        if case .success(let s) = KensingtonWorks.parse(Data(KensingtonWorksSource.sample.utf8)) {
            KensingtonWorksSource.sandboxSettings = s
        }
    }

    /// A name typed for sharing (both switches on, as after typing one).
    static func useSharingName(_ name: String) {
        SharingName.setName(name)
        SharingNameStore.shared.reload()
    }

    static func resetSharing(_ model: AppModel) {
        for key in [SharingName.nameKey, SharingName.picturesKey, SharingName.linksKey, ShareChoiceMemory.key] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        SharingNameStore.shared.reload()
        KensingtonWorksSource.sandboxSettings = nil
        ShareSetupSheet.sandboxDone = nil
        model.pendingIncoming = nil
        model.shareRequest = nil
    }

    /// The Pointer page's header with its share menu drawn open under the button.
    struct ShareMenuMock: View {
        let model: AppModel
        var body: some View {
            VStack(alignment: .trailing, spacing: 6) {
                PageHeader(title: .verbatim(GlideTab.pointer.title), subtitle: .verbatim(GlideTab.pointer.summary)) {
                    PageShareMenu(tab: .pointer, model: model)
                }
                PopoverMock {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(PageShareMenu.kinds(for: .pointer)) { kind in
                            Text(verbatim: PageShareMenu.menuTitle(kind))
                                .font(.system(size: 13))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .frame(width: 230, alignment: .leading)
                                .background(kind == .pointer ? RoundedRectangle(cornerRadius: 5).fill(Theme.ball) : nil)
                                .foregroundStyle(kind == .pointer ? Color.white : Color.primary)
                        }
                    }
                    .padding(5)
                }
            }
            .frame(width: Theme.Space.contentMaxWidth - 40)
        }
    }
}
