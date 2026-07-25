// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

/// The Git-source-of-truth switch, shared by the Diff toolbar and the Apply sheet.
///
/// This setting decides whether Apply DELETES Apple-only configurations, so it gets two
/// guarantees a plain `Toggle` never gave us:
///  1. the current mode is readable at a glance — the literal word ON / OFF, not just a
///     switch position or a tint (colour alone is not an indicator);
///  2. clicking never changes it. A click only stages a *pending* value; the model is
///     changed by `setGitSourceOfTruth` after a confirmation dialog has spelled out what
///     the new mode does to the tenant (which in turn posts the NoticeBanner below).
///
/// WHO presents that dialog depends on where the control lives. Inside a sheet it presents
/// its own. In a macOS toolbar it must NOT: toolbar items live in a separate NSToolbar
/// hierarchy where dialog presentation is unreliable and environment propagation is not
/// guaranteed, and a gate that silently no-ops is worse than no gate. Such a host passes
/// `isOn` + `pending` and attaches `.gitSourceOfTruthConfirmation` to its content view.
struct GitSourceOfTruthControl: View {
    enum Layout { case toolbar, inline }

    let layout: Layout
    /// The current mode when the HOST already has it. nil ⇒ read it from the environment
    /// model. `@Environment(AppModel.self)` is non-optional — an environment that failed to
    /// reach the view would TRAP rather than degrade — so hosts outside the ordinary content
    /// hierarchy (the toolbar) hand the value in instead of betting on it.
    var isOn: Bool? = nil
    /// Non-nil ⇒ the HOST owns the confirmation: a click only writes the staged value here
    /// and `gitSourceOfTruthConfirmation` presents/commits it. nil ⇒ this view owns its own
    /// dialog, which is correct inside a sheet's own view hierarchy.
    var pending: Binding<Bool?>? = nil
    /// Called AFTER a confirmed change (DiffView recomputes the plan; ApplySheet forces prune on).
    var onChange: (Bool) -> Void = { _ in }

    @Environment(AppModel.self) private var model
    /// The self-presenting path's staged value. nil = no dialog in flight, which is also what
    /// drives `isPresented` — the dialog can never open without a value.
    @State private var localPending: Bool?

    /// The mode being displayed: the host's value when it supplied one, else the model's.
    /// `??` takes its right side lazily, so a host that passes `isOn` never touches the
    /// environment at all.
    private var enabled: Bool { isOn ?? model.gitSourceOfTruth }

    var body: some View {
        if let hosted = pending {
            control(staging: hosted) // the host presents the dialog and commits the change
        } else {
            control(staging: $localPending)
                .confirmationDialog(GitSourceOfTruthCopy.title(for: localPending ?? !enabled),
                                    isPresented: localDialogPresented,
                                    titleVisibility: .visible,
                                    presenting: localPending) { value in
                    GitSourceOfTruthCopy.actions(for: value) { confirmed in
                        localPending = nil
                        model.setGitSourceOfTruth(confirmed)
                        onChange(confirmed)
                    } cancel: {
                        localPending = nil
                    }
                } message: { value in
                    Text(GitSourceOfTruthCopy.consequence(of: value, layout: layout))
                }
        }
    }

    /// Presented iff a staged value exists; dismissing (Esc / Cancel) drops it.
    private var localDialogPresented: Binding<Bool> {
        Binding(get: { localPending != nil }, set: { shown in if !shown { localPending = nil } })
    }

    // MARK: the switch itself

    @ViewBuilder private func control(staging staged: Binding<Bool?>) -> some View {
        switch layout {
        case .toolbar:
            Button { staged.wrappedValue = !enabled } label: { row }
                .help(helpText)
                .accessibilityLabel(Text("Git source of truth"))
                .accessibilityValue(Text(enabled ? "on" : "off"))
        case .inline:
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 0) {
                    // Bordered, not plain: this row sits directly above a real Toggle, and a
                    // borderless run of text next to a switch does not read as something you
                    // can click. The border IS the affordance.
                    Button { staged.wrappedValue = !enabled } label: { row }
                        .buttonStyle(.bordered)
                        .help(helpText)
                        .accessibilityLabel(Text("Git source of truth"))
                        .accessibilityValue(Text(enabled ? "on" : "off"))
                        .accessibilityHint(Text("Opens a confirmation before the mode changes"))
                    // The Spacer lives OUTSIDE the button: a hit area spanning the whole sheet
                    // width would open the confirmation on a stray click in the empty space.
                    Spacer(minLength: 0)
                }
                // The sheet has room to explain itself: the meaning of the CURRENT mode, so
                // nobody has to open the dialog just to find out what is about to happen.
                Text(meaning)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var row: some View {
        HStack(spacing: 6) {
            // The symbol encodes the state too (a padlock vs. a two-way arrow), so the row
            // still reads correctly in a screenshot, a mono theme, or at a glance.
            Image(systemName: enabled ? "lock.fill" : "arrow.left.arrow.right")
                .foregroundStyle(enabled ? Color.green : Color.secondary)
            Text("Git source of truth")
            statePill
        }
    }

    /// The literal state. The WORD is the indicator; the tint only reinforces it.
    private var statePill: some View {
        Text(enabled ? "ON" : "OFF")
            .font(.system(.caption, design: .monospaced).weight(.bold))
            .foregroundStyle(enabled ? Color.white : Color.primary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(enabled ? Color.green : Color.secondary.opacity(0.25), in: Capsule())
    }

    // MARK: current-state copy

    /// One-line meaning of the CURRENT mode (tooltip on both layouts).
    private var helpText: String {
        enabled
            ? "ON — Apply changes Apple Business to match gitops/, deleting configurations that exist only in Apple. Click to change."
            : "OFF — sync is additive and newest-wins; Apple-only configurations are pulled into gitops/. Click to change."
    }

    /// The same meaning with room to breathe (inline layout only).
    private var meaning: String {
        enabled
            ? "ON — gitops/ is the complete desired state: Apply DELETES configurations that exist only in Apple and detaches blueprint members removed from git (prune is forced on)."
            : "OFF — sync is additive and newest-wins: Apple-only configurations are pulled into gitops/, and nothing is removed unless you enable \"Allow deletes / detaches (--prune)\" below."
    }
}

/// The reviewed confirmation copy and its buttons, in ONE place: the control presents them
/// itself inside a sheet, and `GitSourceOfTruthConfirmation` presents the identical dialog
/// for hosts whose control sits in a toolbar. Two presenters, one wording.
enum GitSourceOfTruthCopy {
    static func title(for value: Bool) -> String {
        value ? "Turn Git source of truth ON?" : "Turn Git source of truth OFF?"
    }

    /// What the NEW mode will mean — shown before the value changes.
    static func consequence(of value: Bool, layout: GitSourceOfTruthControl.Layout) -> String {
        var text = value
            ? "gitops/ becomes the complete desired state. On Apply, Apple Business is changed to match your repo: configurations that exist only in Apple are DELETED and blueprint members removed from git are detached (prune is forced on). Live-only Apple configurations are no longer pulled into git."
            : "Sync becomes additive and newest-wins. Configurations that exist only in Apple are pulled into gitops/ instead of deleted, and nothing is removed unless you separately enable \"Allow deletes / detaches (--prune)\"."
        // Only the Diff screen recomputes on change; the Apply sheet just re-gates prune.
        if case .toolbar = layout { text += "\n\nThe plan is recomputed after this change." }
        return text
    }

    /// Confirm + Cancel. Turning it ON is `.destructive`: that click is what authorizes
    /// deletes on the next Apply.
    @ViewBuilder
    static func actions(for value: Bool,
                        confirm: @escaping (Bool) -> Void,
                        cancel: @escaping () -> Void) -> some View {
        if value {
            Button("Turn ON", role: .destructive) { confirm(true) }
        } else {
            Button("Turn OFF") { confirm(false) }
        }
        Button("Cancel", role: .cancel) { cancel() }
    }
}

/// Host-owned confirmation for a `GitSourceOfTruthControl` that cannot safely present its
/// own — i.e. one placed in a `.toolbar`.
///
/// Every other presentation in this app hangs off a CONTENT view (ConfigurationsView's
/// dialog, ReadOnlyListView's exporter, DiffView's own sheet/importer); the toolbar builders
/// only ever write `@State`. This keeps that rule intact for the Diff screen's switch: the
/// toolbar item stages a value, and the dialog is presented here, where presentation works.
struct GitSourceOfTruthConfirmation: ViewModifier {
    @Binding var pending: Bool?
    var layout: GitSourceOfTruthControl.Layout = .toolbar
    let onChange: (Bool) -> Void

    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content
            .confirmationDialog(GitSourceOfTruthCopy.title(for: pending ?? !model.gitSourceOfTruth),
                                isPresented: presented,
                                titleVisibility: .visible,
                                presenting: pending) { value in
                GitSourceOfTruthCopy.actions(for: value) { confirmed in
                    pending = nil
                    model.setGitSourceOfTruth(confirmed)
                    onChange(confirmed)
                } cancel: {
                    pending = nil
                }
            } message: { value in
                Text(GitSourceOfTruthCopy.consequence(of: value, layout: layout))
            }
    }

    private var presented: Binding<Bool> {
        Binding(get: { pending != nil }, set: { shown in if !shown { pending = nil } })
    }
}

extension View {
    /// Attach to the screen's CONTENT view when its `GitSourceOfTruthControl` lives in a
    /// toolbar. `pending` is the same `@State` the control stages into.
    func gitSourceOfTruthConfirmation(pending: Binding<Bool?>,
                                      layout: GitSourceOfTruthControl.Layout = .toolbar,
                                      onChange: @escaping (Bool) -> Void = { _ in }) -> some View {
        modifier(GitSourceOfTruthConfirmation(pending: pending, layout: layout, onChange: onChange))
    }
}

/// The transient announcement strip for `model.notice` — a confirmed source-of-truth flip
/// must be visible on screen, not just inside the dialog the user already dismissed.
/// Renders nothing when there is no notice; retires itself after 10 seconds so a screen
/// can never accumulate stale banners.
struct NoticeBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // An always-present (zero-height when empty) container, so the transition has
        // something stable to animate in and out of.
        VStack(spacing: 0) {
            if let notice = model.notice {
                // Kind → symbol + tint, resolved here so the row below reads as one piece.
                let symbol = { () -> String in
                    switch notice.kind {
                    case .info: return "info.circle.fill"
                    case .success: return "checkmark.circle.fill"
                    case .warning: return "exclamationmark.triangle.fill"
                    }
                }()
                let tint = { () -> Color in
                    switch notice.kind {
                    case .info: return .blue
                    case .success: return .green
                    case .warning: return .orange
                    }
                }()
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: symbol)
                        .foregroundStyle(tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(notice.title)
                            .font(.subheadline.weight(.semibold))
                            .textSelection(.enabled)
                        Text(notice.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 0)
                    Button { model.dismissNotice(notice.id) } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Dismiss")
                    // Icon-only: VoiceOver would otherwise announce the raw symbol name, and
                    // this banner is the only on-screen word that the mode changed.
                    .accessibilityLabel(Text("Dismiss notice"))
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal)
                .padding(.top, 6)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: notice.id) {
                    // Re-armed whenever a new notice arrives — the id change cancels this sleep.
                    try? await Task.sleep(for: .seconds(10))
                    guard !Task.isCancelled else { return }
                    model.dismissNotice(notice.id)
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.notice)
    }
}
