import AppKit
import SwiftUI
import UniformTypeIdentifiers

// "Share…": a picture of how you're doing with Glideball (your numbers, or a
// badge), with the trackball in your ball color and Glideball's name and
// website small at the bottom. It's drawn on this Mac with the same offscreen
// renderer `--render-ui` uses (Offscreen.swift), and only goes anywhere if you
// share it, copy it or save it. Nothing is uploaded.

/// What a share picture shows.
enum ShareCard: Equatable {
    /// Lifetime numbers.
    case overview
    /// One badge, and when it was earned.
    case badge(Milestone, Date)

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

    private func badge(_ m: Milestone, _ date: Date) -> some View {
        HStack(spacing: 34) {
            ZStack {
                trackball.opacity(0.9)
                BadgeTile(milestone: m, earned: true, size: 92)
                    .shadow(color: .black.opacity(0.5), radius: 16, y: 8)
                    .offset(x: 62, y: 58)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Badge earned", comment: "Share picture heading for a badge")
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
                Text(verbatim: date.formatted(date: .long, time: .omitted))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.top, 2)
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
    static func render(_ card: ShareCard, delight: DelightCenter) -> NSBitmapImageRep? {
        Offscreen.render(ShareCardView(card: card, delight: delight), size: NSSize(width: ShareCard.size.width, height: ShareCard.size.height),
                         chrome: .plain, appearance: NSAppearance(named: .darkAqua), scale: 2, settle: 0.05)
    }

    static func png(_ rep: NSBitmapImageRep) -> Data? { rep.representation(using: .png, properties: [:]) }

    /// A copy in the temporary folder, for the share sheet (most services want a file).
    static func temporaryFile(_ rep: NSBitmapImageRep, name: String) -> URL? {
        guard let data = png(rep) else { return nil }
        let safe = name.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(safe).appendingPathExtension("png")
        do { try data.write(to: url, options: .atomic); return url } catch { return nil }
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

/// The picture, and what to do with it: Share… (the system share sheet),
/// Copy, or Save as PNG.
struct SharePanel: View {
    let card: ShareCard
    /// Back to whatever opened it (a badge's details), if anything.
    var back: (() -> Void)? = nil
    @State private var image: NSBitmapImageRep?
    @State private var done: String?
    @State private var anchor = AnchorHolder()

    /// Renders: the picture, drawn beforehand (a render can't draw one inside another).
    nonisolated(unsafe) static var sandboxImage: NSBitmapImageRep?

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

            if let done {
                Label(done, systemImage: "checkmark.circle.fill")
                    .font(Theme.Font.hint)
                    .foregroundStyle(Theme.ok)
                    .transition(.opacity)
            }
        }
        .padding(18)
        .frame(width: 420)
        .onAppear {
            if let ready = Self.sandboxImage { image = ready } else { DispatchQueue.main.async { draw() } }
        }
    }

    private var delight: DelightCenter { AppModel.shared.delight }

    private func draw() {
        guard image == nil else { return }
        image = ShareImage.render(card, delight: delight)
    }

    private func share() {
        guard let image, let url = ShareImage.temporaryFile(image, name: card.fileName), let view = anchor.view else { return }
        let picker = NSSharingServicePicker(items: [url])
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }

    private func copy() {
        guard let image, let data = ShareImage.png(image) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(data, forType: .png)
        if let tiff = image.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
        withAnimation(Theme.Motion.fade) { done = String(localized: "Copied. Paste it anywhere.") }
    }

    private func save() {
        guard let image, let data = ShareImage.png(image) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = card.fileName + ".png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
            withAnimation(Theme.Motion.fade) { done = String(localized: "Saved “\(url.deletingPathExtension().lastPathComponent)”") }
        } catch {
            withAnimation(Theme.Motion.fade) { done = String(localized: "Couldn’t save it: \(error.localizedDescription)") }
        }
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
