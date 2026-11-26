// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosDomain
import PhotosMedia
import PhotosModel
import PhotosNetworking
import SwiftUI

enum PostcardWording {
    static var menuTitle: String {
        PlatformWording.title(
            mac: LocalizedStringResource(
                "Send as Postcard…", bundle: .module, comment: "Viewer menu item that opens the postcard composer (Mac)."),
            other: LocalizedStringResource(
                "Send as postcard…", bundle: .module,
                comment: "Viewer menu item that opens the postcard composer (iPhone, iPad, Vision Pro)."))
    }

    static let systemImage = "envelope"
}

/// The photo a postcard is made of.
struct PostcardStart: Identifiable {
    let item: MediaItem
    var id: FileID { item.fileId }
}

/// "Send as postcard…" in the viewer's More menu (photos only).
struct PostcardMenuItem: View {
    let item: MediaItem
    @Binding var start: PostcardStart?

    var body: some View {
        if item.kind == .image {
            Button {
                start = PostcardStart(item: item)
            } label: {
                Label(PostcardWording.menuTitle, systemImage: PostcardWording.systemImage)
            }
        }
    }
}

extension View {
    /// The postcard composer for the viewer's photo, in a sheet.
    func postcardSheet(_ start: Binding<PostcardStart?>) -> some View {
        sheet(item: start) { (start: PostcardStart) in PostcardComposer(item: start.item) }
    }
}

/// Renders the two sides while the user writes, sends the card and keeps what was sent.
@MainActor @Observable final class PostcardModel {
    enum Phase: Equatable {
        case editing, sending, sent, failed(String)
    }

    var content: PostcardContent
    var photo: CGImage?
    var front: CGImage?
    var back: CGImage?
    var layout = PostcardLayout(photoAspectRatio: 1.5)
    var phase: Phase = .editing
    var sent: SentPostcard?
    /// The two sides as files, for the share sheet.
    var files: [URL] = []
    @ObservationIgnored private var renderTask: Task<Void, Never>?

    init(item: MediaItem) {
        let place = item.place ?? ""
        content = PostcardContent(greeting: PostcardContent.defaultGreeting(place: place), place: place, date: item.timestamp)
    }

    func load(_ item: MediaItem, services: AccountServices) async {
        var image = await services.images.preview(ImagePipeline.Request(fileId: item.fileId, etag: item.etag, bucket: 4096))
        if image == nil { image = await services.images.preview(ImagePipeline.Request(fileId: item.fileId, etag: item.etag, bucket: 1024)) }
        guard let image else {
            phase = .failed(String(localized: "The photo could not be loaded.", bundle: .module))
            return
        }
        photo = image
        layout = PostcardLayout(photoAspectRatio: Double(image.width) / Double(max(1, image.height)))
        render(immediately: true)
    }

    /// Draws both sides again, a moment after the last change (typing stays smooth).
    func render(immediately: Bool = false) {
        guard let photo else { return }
        renderTask?.cancel()
        let content = content
        let layout = layout
        renderTask = Task {
            if !immediately { try? await Task.sleep(for: .milliseconds(250)) }
            guard !Task.isCancelled else { return }
            let sides = await Task.detached(priority: .userInitiated) {
                (
                    PostcardRenderer.front(photo: photo, content: content, layout: layout),
                    PostcardRenderer.back(photo: photo, content: content, layout: layout)
                )
            }.value
            guard !Task.isCancelled else { return }
            front = sides.0
            back = sides.1
        }
    }

    func send(session: SessionModel) async {
        await renderTask?.value
        guard let front, let back, let frontData = PostcardRenderer.jpeg(front), let backData = PostcardRenderer.jpeg(back) else { return }
        phase = .sending
        do {
            let directory = FileManager.default.temporaryDirectory.appending(path: "Postcards/\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let frontFile = directory.appending(path: PostcardFiles.frontFileName)
            let backFile = directory.appending(path: PostcardFiles.backFileName)
            try frontData.write(to: frontFile)
            try backData.write(to: backFile)
            files = [frontFile, backFile]
            sent = try await session.sendPostcard(front: frontData, back: backData, content: content)
            phase = .sent
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func cleanUp() {
        for file in files { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    }
}

/// Write a postcard: pick a frame, add "Greetings from …", turn the card over and write the message. Sending puts the
/// card into Nextcloud with a public link, flips it with a "Sent" stamp, and offers the share sheet for Messages or Mail.
struct PostcardComposer: View {
    let item: MediaItem
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var model: PostcardModel
    @State private var showsBack = false
    @State private var stamped = false
    @State private var copied = false
    @FocusState private var focused: Field?

    enum Field {
        case greeting, message, recipient, place
    }

    init(item: MediaItem) {
        self.item = item
        _model = State(initialValue: PostcardModel(item: item))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    card
                    if model.phase == .sent {
                        sentActions
                    } else {
                        Picker(
                            String(localized: "Side", bundle: .module, comment: "Picker between the front and the back of a postcard."),
                            selection: $showsBack
                        ) {
                            Text("Front", bundle: .module, comment: "The front (picture side) of a postcard.").tag(false)
                            Text("Back", bundle: .module, comment: "The back (writing side) of a postcard.").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        if showsBack { backFields } else { frontFields }
                        if case .failed(let message) = model.phase {
                            Text(message).font(.footnote).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Text(
                            "The card is saved in Postcards in your Nextcloud and shared by a public link. Anyone with the link can see it.",
                            bundle: .module, comment: "Footnote of the postcard composer."
                        )
                        .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(String(localized: "Postcard", bundle: .module, comment: "Title of the postcard composer."))
            #if !os(macOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { toolbar }
            .task {
                guard let services = session.services else { return }
                await model.load(item, services: services)
            }
            .onChange(of: model.content) { _, _ in model.render() }
            .onDisappear { model.cleanUp() }
            .sensoryFeedback(.success, trigger: stamped) { _, new in new }
        }
        #if os(macOS)
            .frame(minWidth: 560, minHeight: 640)
        #endif
    }

    @ToolbarContentBuilder var toolbar: some ToolbarContent {
        if model.phase == .sent {
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "Done", bundle: .module)) { dismiss() }
            }
        } else {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "Cancel", bundle: .module)) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                if model.phase == .sending {
                    ProgressView()
                } else {
                    Button(String(localized: "Send", bundle: .module, comment: "Sends the postcard.")) {
                        focused = nil
                        Task { await send() }
                    }
                    .disabled(model.front == nil || model.back == nil)
                }
            }
        }
    }

    var card: some View {
        PostcardFlipView(
            front: model.front, back: model.back, aspectRatio: model.layout.size.width / model.layout.size.height, showsBack: $showsBack
        )
        .overlay {
            if stamped { SentStamp().transition(.scale(scale: 2.4).combined(with: .opacity)) }
        }
        .scaleEffect(model.phase == .sent ? 0.92 : 1)
        .rotationEffect(.degrees(model.phase == .sent ? -2 : 0))
        .animation(.spring(response: 0.55, dampingFraction: 0.7), value: model.phase == .sent)
    }

    @ViewBuilder var frontFields: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(PostcardStyle.allCases) { (style: PostcardStyle) in
                    Button {
                        model.content.style = style
                    } label: {
                        Text(style.title)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(
                                model.content.style == style ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12), in: .capsule
                            )
                            .overlay { Capsule().strokeBorder(model.content.style == style ? Color.accentColor : .clear, lineWidth: 1.5) }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(model.content.style == style ? .isSelected : [])
                }
            }
        }
        TextField(
            String(
                localized: "Lettering, e.g. Greetings from Lisbon", bundle: .module,
                comment: "Placeholder of the lettering field on a postcard's front."),
            text: $model.content.greeting
        )
        .textFieldStyle(.roundedBorder)
        .focused($focused, equals: .greeting)
    }

    @ViewBuilder var backFields: some View {
        TextField(
            String(localized: "To", bundle: .module, comment: "Field for the name a postcard is addressed to."),
            text: $model.content.recipient
        )
        .textFieldStyle(.roundedBorder)
        .focused($focused, equals: .recipient)
        VStack(alignment: .trailing, spacing: 4) {
            TextEditor(text: $model.content.message)
                .focused($focused, equals: .message)
                .frame(minHeight: 120)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color.secondary.opacity(0.1), in: .rect(cornerRadius: 8))
                .overlay(alignment: .topLeading) {
                    if model.content.message.isEmpty {
                        Text("Write a message…", bundle: .module, comment: "Placeholder of the postcard message.")
                            .foregroundStyle(.tertiary).padding(12).allowsHitTesting(false)
                    }
                }
                .onChange(of: model.content.message) { _, text in
                    if text.count > PostcardContent.maximumMessageLength {
                        model.content.message = String(text.prefix(PostcardContent.maximumMessageLength))
                    }
                }
                .accessibilityLabel(Text("Message", bundle: .module, comment: "Accessibility label of the postcard message field."))
            Text(verbatim: "\(model.content.message.count)/\(PostcardContent.maximumMessageLength)")
                .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
        }
        TextField(
            String(localized: "Place on the postmark", bundle: .module, comment: "Field for the place on a postcard's postmark."),
            text: $model.content.place
        )
        .textFieldStyle(.roundedBorder)
        .focused($focused, equals: .place)
    }

    @ViewBuilder var sentActions: some View {
        VStack(spacing: 14) {
            if let link = model.sent?.link {
                Text("Your postcard is on its way.", bundle: .module, comment: "Shown after a postcard was sent.").font(.headline)
                HStack {
                    Text(link.absoluteString).font(.footnote.monospaced()).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Spacer()
                    Button {
                        Clipboard.copyLink(link.absoluteString)
                        copied = true
                    } label: {
                        Label(
                            copied
                                ? String(
                                    localized: "Copied", bundle: .module,
                                    comment: "Shown on the copy button after the postcard link was copied.")
                                : String(localized: "Copy link", bundle: .module),
                            systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                }
                .padding(10)
                .background(Color.secondary.opacity(0.1), in: .rect(cornerRadius: 10))
            } else {
                Text(
                    "The postcard is saved in your Nextcloud. This server doesn't allow public links, so share the pictures instead.",
                    bundle: .module, comment: "Shown after a postcard was saved when public links are not allowed."
                )
                .font(.callout).multilineTextAlignment(.center)
            }
            ShareLink(
                items: model.files,
                subject: Text("A postcard for you", bundle: .module, comment: "Subject of the mail a postcard is shared in."),
                message: Text(model.sent?.link?.absoluteString ?? "")
            ) {
                Label(
                    String(
                        localized: "Share Postcard", bundle: .module,
                        comment: "Opens the share sheet with the postcard's pictures and link."), systemImage: "square.and.arrow.up"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    func send() async {
        await model.send(session: session)
        guard model.phase == .sent else { return }
        // The card turns over, gets its stamp, and settles.
        withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) { showsBack = true }
        try? await Task.sleep(for: .milliseconds(650))
        withAnimation(.spring(response: 0.35, dampingFraction: 0.55)) { stamped = true }
    }
}

/// The two sides of a card; turning it over is a 3D flip around the vertical axis. Tap to turn.
struct PostcardFlipView: View {
    let front: CGImage?
    let back: CGImage?
    let aspectRatio: CGFloat
    @Binding var showsBack: Bool

    var body: some View {
        ZStack {
            side(front).modifier(FlipSide(angle: showsBack ? 180 : 0, isBack: false))
            side(back).modifier(FlipSide(angle: showsBack ? 180 : 0, isBack: true))
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
        .animation(.spring(response: 0.6, dampingFraction: 0.8), value: showsBack)
        .contentShape(.rect)
        .onTapGesture { showsBack.toggle() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            showsBack
                ? Text("Back of the postcard", bundle: .module, comment: "Accessibility label of the postcard preview, writing side.")
                : Text("Front of the postcard", bundle: .module, comment: "Accessibility label of the postcard preview, picture side.")
        )
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Text("Turns the card over.", bundle: .module, comment: "Accessibility hint of the postcard preview."))
        .accessibilityAction { showsBack.toggle() }
    }

    func side(_ image: CGImage?) -> some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
            } else {
                Rectangle().fill(Color.secondary.opacity(0.12)).overlay { ProgressView() }
            }
        }
        .clipShape(.rect(cornerRadius: 6))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
    }
}

/// Shows one side of the card while it faces the viewer, rotated with the card.
private struct FlipSide: @MainActor ViewModifier, @MainActor Animatable {
    var angle: Double
    let isBack: Bool

    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    func body(content: Content) -> some View {
        let facing = isBack ? angle > 90 : angle <= 90
        turned(content).opacity(facing ? 1 : 0)
    }

    private func turned(_ content: Content) -> some View {
        let turn: Angle = .degrees(isBack ? angle - 180 : angle)
        #if os(visionOS)
            // Real depth on Vision Pro: no perspective to imitate.
            return content.rotation3DEffect(turn, axis: .y)
        #else
            return content.rotation3DEffect(turn, axis: (x: 0, y: 1, z: 0), perspective: 0.45)
        #endif
    }
}

/// A red rubber stamp, "SENT".
private struct SentStamp: View {
    var body: some View {
        Text("Sent", bundle: .module, comment: "Rubber stamp on a postcard that was sent. Short; shown in capitals.")
            .textCase(.uppercase)
            .font(.system(size: 44, weight: .black, design: .serif))
            .kerning(6)
            .foregroundStyle(Color.red.opacity(0.85))
            .padding(.horizontal, 18).padding(.vertical, 6)
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.red.opacity(0.85), lineWidth: 5) }
            .rotationEffect(.degrees(-14))
            .accessibilityLabel(Text("Sent", bundle: .module))
    }
}
