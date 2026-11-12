import AppKit
import SwiftUI
import UniformTypeIdentifiers

// "Share…": a picture of how you're doing with Glideball (your numbers, or a
// badge), with the trackball in your ball color and Glideball's name and
// website small at the bottom. It's drawn on this Mac with SwiftUI's
// ImageRenderer, and only goes anywhere if you share it, copy it or save it.
// Nothing is uploaded: the X, LinkedIn, Facebook and Instagram buttons copy the
// picture and open that site's own composer in the browser, where you paste it.
//
// 2.10 beta 10 crashed on a badge's Share…: the picture was drawn with the
// offscreen-window renderer (Offscreen.swift), which turns the run loop while it
// settles. Swapping the badge popover's content for the share panel makes AppKit
// animate the popover's resize in a nested run loop of its own; our drawing ran
// inside that one and closed a window whose display-cycle observer AppKit was
// about to call (EXC_BAD_ACCESS at 0 in __CFRunLoopDoObservers). ImageRenderer
// draws in one synchronous pass: no window, no run-loop turn.

/// What a share picture shows.
enum ShareCard: Equatable {
    /// Lifetime numbers.
    case overview
    /// One badge, and when it was earned (nil: not yet, it's the one you're working toward).
    case badge(Milestone, Date?)

    /// Points; drawn at 2x (1200 × 750 pixels).
    static let size = CGSize(width: 600, height: 375)

    var fileName: String {
        switch self {
        case .overview: String(localized: "My Glideball", comment: "Share picture file name")
        case .badge(let m, _): String(localized: "Glideball badge – \(m.title)", comment: "Share picture file name; %@ is a badge name")
        }
    }
}

/// The picture itself, always dark (it's the trackball's stage).
struct ShareCardView: View {
    let card: ShareCard
    let delight: DelightCenter

    var body: some View {
        let size = ShareCard.size
        ZStack {
            Color(red: 0.035, green: 0.035, blue: 0.05)
            // The ball's light filling the stage, in the ball's own colors.
            RadialGradient(colors: [Theme.orbBlue.opacity(0.55), Theme.orbViolet.opacity(0.22), .clear],
                           center: UnitPoint(x: 0.24, y: 0.45), startRadius: 10, endRadius: 330)
            RadialGradient(colors: [Theme.orbMagenta.opacity(0.16), .clear],
                           center: UnitPoint(x: 0.9, y: 1.0), startRadius: 0, endRadius: 300)
            RadialGradient(colors: [Theme.orbCyan.opacity(0.14), .clear],
                           center: UnitPoint(x: 0.55, y: 0.0), startRadius: 0, endRadius: 260)
            // A faint echo of the ring around where the ball sits.
            ForEach(1..<5, id: \.self) { i in
                Circle()
                    .stroke(Color.white.opacity(0.045 - Double(i) * 0.008), lineWidth: 1)
                    .frame(width: 210 + CGFloat(i) * 70, height: 210 + CGFloat(i) * 70)
                    .position(x: size.width * 0.24, y: size.height * 0.45)
            }

            switch card {
            case .overview: overview
            case .badge(let m, let date): badge(m, date)
            }

            VStack {
                Spacer()
                HStack(spacing: 7) {
                    Image(nsImage: AppIconChoice.shared.image(for: .orb))
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 20, height: 20)
                    Text(verbatim: "Glideball").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(verbatim: "glideball.netlify.app")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .padding(.horizontal, 26)
                .padding(.bottom, 18)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    private var trackball: some View {
        var pose = TrackballPose()
        pose.orientation = BallSpin.rolled(0.4, direction: CGVector(dx: 1, dy: -0.5))
        pose.flare = 0.25
        return TrackballArt(pose: pose)
            .frame(width: 196, height: 196)
            .shadow(color: Theme.orbBlue.opacity(0.35), radius: 30)
    }

    private var overview: some View {
        HStack(spacing: 30) {
            trackball
            VStack(alignment: .leading, spacing: 13) {
                Text("My trackball, so far", comment: "Share picture heading")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.62))
                ForEach(Metric.lifetimeOrder) { m in
                    let v = delight.lifetime.value(m)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: m.format(v))
                            .font(.system(size: 30, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        HStack(spacing: 6) {
                            Circle().fill(m.color).frame(width: 7, height: 7)
                            Text(verbatim: label(m, v))
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(.white.opacity(0.62))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                    }
                }
                Text("\(delight.ledger.earned.count) of \(Milestone.all.count) badges", comment: "Share picture: badges earned")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 34)
        .padding(.trailing, 26)
        .padding(.bottom, 34)
        .environment(\.colorScheme, .dark)
    }

    /// "clicks", "rolled · ≈ 2.1 × the Golden Gate Bridge"…
    private func label(_ m: Metric, _ v: Double) -> String {
        let base: String = switch m {
        case .clicks: String(localized: "clicks", comment: "Share picture: under the number of clicks")
        case .ball: String(localized: "rolled", comment: "Share picture: under the distance the ball rolled")
        case .scroll: String(localized: "scrolled", comment: "Share picture: under the distance scrolled")
        }
        guard let compare = Landmarks.compare(v, metric: m) else { return base }
        return base + " · " + compare
    }

    private func badge(_ m: Milestone, _ date: Date?) -> some View {
        HStack(spacing: 34) {
            ZStack {
                trackball.opacity(0.9)
                BadgeTile(milestone: m, earned: date != nil, size: 92)
                    .shadow(color: .black.opacity(0.5), radius: 16, y: 8)
                    .offset(x: 62, y: 58)
            }
            VStack(alignment: .leading, spacing: 8) {
                Group {
                    if date != nil {
                        Text("Badge earned", comment: "Share picture heading for a badge")
                    } else {
                        Text("Working toward", comment: "Share picture heading for a badge that isn't earned yet")
                    }
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(m.color.mix(with: .white, by: 0.3))
                Text(verbatim: m.title)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                Text(verbatim: m.detail)
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
                if let date {
                    Text(verbatim: date.formatted(date: .long, time: .omitted))
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 34)
        .padding(.trailing, 30)
        .padding(.bottom, 34)
    }
}

/// Draws a share picture to a bitmap, on this Mac.
@MainActor
enum ShareImage {
    /// One synchronous SwiftUI pass (no window, no run-loop turn), so it's safe from
    /// anywhere: inside a popover that's resizing, during an animation, at launch.
    static func render(_ card: ShareCard, delight: DelightCenter) -> NSBitmapImageRep? {
        let renderer = ImageRenderer(content: ShareCardView(card: card, delight: delight))
        renderer.proposedSize = ProposedViewSize(ShareCard.size)
        renderer.scale = 2
        renderer.isOpaque = true
        guard let cg = renderer.cgImage else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = ShareCard.size
        return rep
    }

    static func png(_ rep: NSBitmapImageRep) -> Data? { rep.representation(using: .png, properties: [:]) }

    /// A copy in the temporary folder, for the share sheet (most services want a file).
    static func temporaryFile(_ rep: NSBitmapImageRep, name: String) -> URL? {
        guard let data = png(rep) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(safeName(name)).appendingPathExtension("png")
        do { try data.write(to: url, options: .atomic); return url } catch { return nil }
    }

    static func safeName(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }

    /// Puts the picture on the clipboard (PNG, and TIFF for apps that only take that).
    @discardableResult
    static func copy(_ rep: NSBitmapImageRep) -> Bool {
        guard let data = png(rep) else { return false }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(data, forType: .png)
        if let tiff = rep.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
        return true
    }

    /// Saves the picture in `folder` (Downloads) under a name that isn't taken yet.
    static func save(_ rep: NSBitmapImageRep, name: String, in folder: URL?) -> URL? {
        guard let data = png(rep), let folder else { return nil }
        var url = folder.appendingPathComponent(safeName(name)).appendingPathExtension("png")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(safeName(name)) \(n)").appendingPathExtension("png")
            n += 1
        }
        do { try data.write(to: url, options: .withoutOverwriting); return url } catch { return nil }
    }

    static var downloads: URL? {
        // `--self-test` and `--render-ui` never write outside their temp folder.
        Sandbox.isActive ? Sandbox.folder : FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    }
}

/// The sites the share panel opens a post on. None of them takes a picture by
/// link, so each button copies the picture first and opens the site's own
/// composer in the browser, with words filled in where the site allows it.
/// Glideball itself sends nothing anywhere.
enum SocialSite: String, CaseIterable, Identifiable {
    case x, linkedIn, facebook, instagram
    var id: String { rawValue }

    /// Brand names, never translated.
    var name: String {
        switch self {
        case .x: "X"
        case .linkedIn: "LinkedIn"
        case .facebook: "Facebook"
        case .instagram: "Instagram"
        }
    }

    /// The page that opens in the browser, with `text` filled in where the site takes it.
    func composer(text: String) -> URL {
        var c: URLComponents
        switch self {
        case .x:
            c = URLComponents(string: "https://x.com/intent/post")!
            c.queryItems = [URLQueryItem(name: "text", value: text), URLQueryItem(name: "url", value: SiteLinks.base)]
        case .linkedIn:
            // LinkedIn's share link only takes a page, not words; its composer takes both.
            c = URLComponents(string: "https://www.linkedin.com/feed/")!
            c.queryItems = [URLQueryItem(name: "shareActive", value: "true"),
                            URLQueryItem(name: "text", value: text + " " + SiteLinks.base)]
        case .facebook:
            // Facebook's sharer takes a link and no words.
            c = URLComponents(string: "https://www.facebook.com/sharer/sharer.php")!
            c.queryItems = [URLQueryItem(name: "u", value: SiteLinks.base)]
        case .instagram:
            // Instagram takes posts only from its own app and site, as uploads.
            c = URLComponents(string: "https://www.instagram.com/")!
        }
        // A + in the words must stay a +, not become a space.
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return c.url!
    }
}

/// Everything Share… hands out for one picture: the PNG, a file for the share
/// sheet, the words for a post and each site's composer. Built in one place so
/// the self-test can check the whole set.
@MainActor
struct ShareItems {
    let png: Data
    let file: URL
    let text: String
    let composers: [SocialSite: URL]

    init?(card: ShareCard, image: NSBitmapImageRep, delight: DelightCenter) {
        guard let png = ShareImage.png(image), let file = ShareImage.temporaryFile(image, name: card.fileName) else { return nil }
        self.png = png
        self.file = file
        text = Self.postText(card, delight: delight)
        var c: [SocialSite: URL] = [:]
        for site in SocialSite.allCases { c[site] = site.composer(text: text) }
        composers = c
    }

    /// A short post made from the picture's own numbers.
    static func postText(_ card: ShareCard, delight: DelightCenter) -> String {
        switch card {
        case .overview:
            let t = delight.lifetime
            let clicks = Metric.clicks.format(t.value(.clicks))
            let ball = Metric.ball.format(t.value(.ball))
            let scroll = Metric.scroll.format(t.value(.scroll))
            return String(localized: "My trackball so far: \(clicks) clicks, \(ball) rolled and \(scroll) scrolled. Glideball counts it all; it’s a free Mac app for Kensington trackballs.",
                          comment: "Post text for sharing your numbers; the first %@ is a number of clicks, the other two are distances")
        case .badge(let m, .some):
            return String(localized: "I just earned “\(m.title)” in Glideball: \(m.detail). It’s a free Mac app for Kensington trackballs.",
                          comment: "Post text for sharing a badge; the first %@ is the badge's name, the second what earned it")
        case .badge(let m, .none):
            return String(localized: "I’m working toward “\(m.title)” in Glideball: \(m.detail). It’s a free Mac app for Kensington trackballs.",
                          comment: "Post text for sharing a badge not earned yet; the first %@ is the badge's name, the second what earns it")
        }
    }
}

/// "Share…" next to a section title: opens the share panel in a popover.
struct ShareButton: View {
    let card: ShareCard
    @State private var open = false

    var body: some View {
        Button {
            open = true
        } label: {
            Label("Share…", systemImage: "square.and.arrow.up")
        }
        .controlSize(.small)
        .help("Make a picture of your numbers to share")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            SharePanel(card: card)
        }
    }
}

/// The picture, and what to do with it: Share… (the system share sheet), Copy,
/// Save as PNG, or a post on X, LinkedIn, Facebook or Instagram. Its size never
/// changes once it's open (a popover that resizes animates in a nested run loop).
struct SharePanel: View {
    let card: ShareCard
    /// Back to whatever opened it (a badge's details), if anything.
    var back: (() -> Void)? = nil
    @State private var image: NSBitmapImageRep?
    @State private var done: String?
    @State private var anchor = AnchorHolder()

    /// Renders: the picture, drawn beforehand.
    nonisolated(unsafe) static var sandboxImage: NSBitmapImageRep?
    /// Renders: the note a site's button leaves, as if it had been clicked.
    nonisolated(unsafe) static var sandboxDone: String?
    /// The self-test: how many pictures panels have drawn.
    nonisolated(unsafe) static var drawnCount = 0

    static let width: CGFloat = 420

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if let back {
                    Button {
                        back()
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                Text("Share your Glideball").font(Theme.Font.emphasis)
                Spacer()
            }
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.well)
                if let image, let cg = image.cgImage {
                    Image(decorative: cg, scale: 2)
                        .resizable()
                        .interpolation(.high)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 384, height: 240)
            .pixelBorder(RoundedRectangle(cornerRadius: 12, style: .continuous), Theme.groupBorder)

            Text("The picture is made on your Mac. It only goes somewhere if you share it.")
                .font(Theme.Font.hint)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button {
                    share()
                } label: {
                    Label("Share…", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.ball)
                .background(SharingAnchor(holder: anchor))
                Button {
                    copy()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                Button {
                    save()
                } label: {
                    Label("Save as PNG…", systemImage: "square.and.arrow.down")
                }
                Spacer(minLength: 0)
            }
            .disabled(image == nil)
            .controlSize(.regular)

            HStack(spacing: 6) {
                Text("Post on", comment: "Share panel: before the X, LinkedIn, Facebook and Instagram buttons")
                    .font(Theme.Font.hint)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                ForEach(SocialSite.allCases) { site in
                    Button(site.name) { post(site) }
                        .controlSize(.small)
                        .help(site == .instagram
                              ? String(localized: "Saves the picture to Downloads and opens Instagram")
                              : String(localized: "Copies the picture and opens \(site.name) to paste it into a post",
                                       comment: "Share panel button tooltip; %@ is X, LinkedIn or Facebook"))
                }
                Spacer(minLength: 0)
            }
            .disabled(image == nil)

            // Room for one line of news is always there, so the popover never resizes.
            Group {
                if let done {
                    Label(done, systemImage: "checkmark.circle.fill")
                        .font(Theme.Font.hint)
                        .foregroundStyle(Theme.ok)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .topLeading)
        }
        .padding(18)
        .frame(width: Self.width)
        .onAppear {
            if let ready = Self.sandboxImage { image = ready; done = Self.sandboxDone } else { draw() }
        }
    }

    private var delight: DelightCenter { AppModel.shared.delight }

    private func draw() {
        guard image == nil else { return }
        image = ShareImage.render(card, delight: delight)
        Self.drawnCount += 1
    }

    private func items() -> ShareItems? {
        guard let image else { return nil }
        return ShareItems(card: card, image: image, delight: delight)
    }

    private func share() {
        guard let items = items(), let view = anchor.view, view.window != nil else { return }
        let picker = NSSharingServicePicker(items: [items.file])
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }

    private func copy() {
        guard let image, ShareImage.copy(image) else { return }
        say(String(localized: "Copied. Paste it anywhere."))
    }

    private func save() {
        guard let image, let data = ShareImage.png(image) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = card.fileName + ".png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
            say(String(localized: "Saved “\(url.deletingPathExtension().lastPathComponent)”"))
        } catch {
            say(String(localized: "Couldn’t save it: \(error.localizedDescription)"))
        }
    }

    /// Copies the picture (and for Instagram saves it to Downloads), then opens the site's composer.
    private func post(_ site: SocialSite) {
        guard let image, let items = items() else { return }
        ShareImage.copy(image)
        if site == .instagram {
            guard ShareImage.save(image, name: card.fileName, in: ShareImage.downloads) != nil else {
                return say(String(localized: "Couldn’t save it to Downloads. Try Save as PNG… instead."))
            }
            say(String(localized: "Saved to Downloads. Instagram only takes uploads from its app or site."))
        } else {
            say(String(localized: "Picture copied. Paste it into the post."))
        }
        guard !Sandbox.isActive, let url = items.composers[site] else { return }
        NSWorkspace.shared.open(url)
    }

    private func say(_ text: String) {
        withAnimation(Theme.Motion.fade) { done = text }
    }
}

/// Keeps the NSView the share sheet appears from.
final class AnchorHolder {
    weak var view: NSView?
}

private struct SharingAnchor: NSViewRepresentable {
    let holder: AnchorHolder
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        holder.view = v
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) { holder.view = nsView }
}
