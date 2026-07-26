// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import AppKit

/// The one log pane in the sync path: `abctl`'s live narration, rendered so it can actually be
/// read and copied. ApplySheet's progress box, DiffView's progress log and ValidateSheet's
/// external-validator output are all this view now.
///
/// The whole transcript is ONE `Text`, not a `Text` per line. That is the entire reason this
/// component exists: a stack of per-line `Text`s draws identically but each one owns its own
/// selection, so a drag can never cross a line boundary and "copy the log" degrades into copying
/// one line at a time. A single string is selectable end-to-end — and the Copy button beside the
/// title means the common case needs no selection at all.
///
/// Height is the other half of the complaint. A 150pt pane nested inside another `ScrollView`
/// inside a non-resizable sheet has almost no room to show that there is more below the fold, and
/// `.scrollIndicators(.visible)` cannot fix that on its own: macOS treats indicator visibility as a
/// user preference ("Show scroll bars: automatically" still auto-hides the overlay scroller). So the
/// pane can be GROWN toward the sheet's full height instead of fought over a few pixels of scroller.
struct TranscriptView: View {
    let title: String
    /// Already joined. Held as one string rather than `[String]` because that is both what gets
    /// rendered and what gets copied — deriving it twice per update would be the same work done
    /// worse, and `.onChange(of:)` needs a single value to compare anyway.
    let text: String
    var placeholder = "Starting…"
    /// The log file abctl wrote for the last run, when there is one: copy-the-path and
    /// reveal-in-Finder hang off this and disappear entirely when it is nil.
    var logURL: URL?
    var collapsedHeight: CGFloat = 150
    var expandedHeight: CGFloat = 520
    /// Tail the output as it arrives. True for a LIVE log (a run in progress ends at the line you
    /// need); false for a finished, static one — a validator report that opens scrolled to its last
    /// line has hidden the first error rather than revealed the last.
    var follow = true
    /// Optional external control of the expand toggle, for a host that must resize ITSELF when the
    /// pane grows (ApplySheet's sheet frame). nil = the pane owns the state privately.
    var expansion: Binding<Bool>?

    init(title: String,
         lines: [String],
         placeholder: String = "Starting…",
         logURL: URL? = nil,
         collapsedHeight: CGFloat = 150,
         expandedHeight: CGFloat = 520,
         follow: Bool = true,
         expansion: Binding<Bool>? = nil) {
        self.init(title: title,
                  text: lines.joined(separator: "\n"),
                  placeholder: placeholder,
                  logURL: logURL,
                  collapsedHeight: collapsedHeight,
                  expandedHeight: expandedHeight,
                  follow: follow,
                  expansion: expansion)
    }

    init(title: String,
         text: String,
         placeholder: String = "Starting…",
         logURL: URL? = nil,
         collapsedHeight: CGFloat = 150,
         expandedHeight: CGFloat = 520,
         follow: Bool = true,
         expansion: Binding<Bool>? = nil) {
        self.title = title
        self.text = text
        self.placeholder = placeholder
        self.logURL = logURL
        self.collapsedHeight = collapsedHeight
        self.expandedHeight = expandedHeight
        self.follow = follow
        self.expansion = expansion
    }

    /// Used when the caller doesn't supply a binding.
    @State private var localExpanded = false

    /// Whether the view is following the tail. Flipped by the geometry probe below: true while the
    /// end of the log is on screen, false the moment the reader scrolls up to look at something.
    @State private var pinnedToBottom = true

    /// The scroll target. A one-pixel spacer AFTER the text, so `anchor: .bottom` lands on the true
    /// end of the transcript rather than the last line of a `Text` whose height keeps changing.
    private static let bottomAnchor = "abgui.transcript.bottom"
    private static let scrollSpace = "abgui.transcript.scroll"
    /// Roughly two monospaced caption lines: close enough to the end still counts as "following",
    /// so a line arriving mid-scroll doesn't unpin the view.
    private static let pinSlack: CGFloat = 24

    /// The wording the Command Log uses, for the same reason. Credentials are redacted, and that is
    /// ALL that redaction promises — the transcript still names the tenant and the workspace.
    static let sharingCaveat =
        "Copied output still names your connection, its configurations and the workspace path, so review it before sharing."

    private var isExpanded: Bool { expansion?.wrappedValue ?? localExpanded }

    private func setExpanded(_ value: Bool) {
        if let expansion {
            expansion.wrappedValue = value
        } else {
            localExpanded = value
        }
    }

    /// What is copied: the transcript verbatim, exactly as displayed. Not decorated with a title or
    /// a timestamp — this text is pasted into tickets and terminals, where added ceremony is noise.
    private var copyText: String { text }

    private var displayText: String { text.isEmpty ? placeholder : text }

    private var lineCount: Int { text.isEmpty ? 0 : text.lazy.filter { $0 == "\n" }.count + 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            transcript
            footer
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if lineCount > 0 {
                // A pane this short hides most of a long run; saying how much there is at least
                // makes the missing part visible before it is scrolled to.
                Text("\(lineCount) line(s)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            expandButton
            CommandCopyButton(text: copyText,
                              title: "Copy Log",
                              help: "Copy the whole transcript to the clipboard. " + Self.sharingCaveat)
                .disabled(text.isEmpty)
        }
    }

    private var expandButton: some View {
        Button {
            setExpanded(!isExpanded)
        } label: {
            Image(systemName: isExpanded
                  ? "arrow.down.right.and.arrow.up.left"
                  : "arrow.up.left.and.arrow.down.right")
        }
        .buttonStyle(.plain)
        .controlSize(.small)
        .foregroundStyle(.secondary)
        .help(isExpanded
              ? "Shrink the log back to its normal size."
              : "Grow the log to fill the window — easier than scrolling a short pane.")
        .accessibilityLabel(Text(isExpanded ? "Collapse log" : "Expand log"))
    }

    private var transcript: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(displayText)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(height: 1).id(Self.bottomAnchor)
                    }
                    .padding(8)
                    .background(bottomProbe(viewportHeight: viewport.size.height))
                }
                .coordinateSpace(name: Self.scrollSpace)
                // Necessary but NOT sufficient — see the type comment. The expand toggle is the
                // affordance that actually solves "I can't tell there's more".
                .scrollIndicators(.visible)
                .onChange(of: text) { _, _ in scrollToBottom(proxy) }
                // Covers first appearance (a sheet reopened over a finished run must show the END
                // of it) and the re-layout after the pane grows or shrinks.
                .task(id: isExpanded) {
                    await Task.yield()
                    scrollToBottom(proxy)
                }
            }
        }
        // The ideal is load-bearing, not decoration: this pane sits inside ANOTHER ScrollView in
        // both sheets, which proposes an unspecified height — and a GeometryReader offered no
        // height at all reports a 10pt default, collapsing the log to its minimum. Stating the
        // ideal makes the unconstrained case resolve to exactly the size asked for, while the
        // min/max still let a squeezed sheet shrink it.
        .frame(minHeight: isExpanded ? 240 : 110,
               idealHeight: isExpanded ? expandedHeight : collapsedHeight,
               maxHeight: isExpanded ? expandedHeight : collapsedHeight)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .contextMenu {
            Button("Copy Log") { CommandClipboard.copy(copyText) }
                .disabled(text.isEmpty)
            Button(isExpanded ? "Collapse" : "Expand") { setExpanded(!isExpanded) }
            if let logURL {
                Divider()
                Button("Copy Log File Path") { CommandClipboard.copy(logURL.path) }
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([logURL]) }
            }
        }
    }

    /// Follow the tail only while the reader is already AT the tail. Measured rather than assumed:
    /// the content's bottom edge, in the scroll view's own coordinate space, sits at the viewport
    /// height exactly when the end is on screen. Without this the pane yanks itself back down every
    /// time a line arrives, which makes reading the error that scrolled past impossible.
    ///
    /// A probe instead of a `PreferenceKey` because `onPreferenceChange`'s action is `@Sendable` on
    /// current SDKs and this has to write `@State` on the main actor.
    private func bottomProbe(viewportHeight: CGFloat) -> some View {
        GeometryReader { content in
            let bottom = content.frame(in: .named(Self.scrollSpace)).maxY
            Color.clear
                .onChange(of: bottom) { _, newValue in
                    // A viewport of zero is a layout pass that hasn't happened yet; reading it
                    // would unpin the log before it ever drew a line.
                    guard viewportHeight > 0 else { return }
                    let atBottom = newValue <= viewportHeight + Self.pinSlack
                    if atBottom != pinnedToBottom { pinnedToBottom = atBottom }
                }
        }
    }

    /// Deliberately NOT animated. An animated scroll walks the offset through every intermediate
    /// position, and the probe above reads those intermediate frames as "scrolled up" — so an
    /// animated auto-follow unpins itself and stops following after the first burst of output.
    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard follow, pinnedToBottom, !text.isEmpty else { return }
        proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
    }

    @ViewBuilder private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let logURL {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    // Truncated in the MIDDLE: the file name at the tail is what identifies the
                    // run, and a head-truncated path drops exactly that.
                    Text(logURL.path)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(logURL.path)
                    CommandCopyButton(text: logURL.path,
                                      title: "Copy Log File Path",
                                      help: "Copy the full path of the log file abctl wrote for this run.")
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([logURL])
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.plain)
                    .controlSize(.small)
                    .foregroundStyle(.secondary)
                    .help("Show the log file in Finder.")
                    .accessibilityLabel(Text("Reveal log file in Finder"))
                    Spacer(minLength: 0)
                }
            }
            Text(Self.sharingCaveat)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
