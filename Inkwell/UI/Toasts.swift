import SwiftUI

/// In-app notifications: a short banner, optionally with an action such as Undo, that goes away
/// on its own. One per window; a new one replaces the current one.
@MainActor @Observable
final class Toaster {
    struct Toast: Identifiable {
        enum Style {
            case info, success, error
        }

        let id = UUID()
        var message: String
        var systemImage: String
        var style: Style
        var actionTitle: String?
        var action: (@MainActor () -> Void)?
    }

    private(set) var current: Toast?
    @ObservationIgnored private var dismissTask: Task<Void, Never>?

    func show(_ message: String, systemImage: String, style: Toast.Style = .info,
              actionTitle: String? = nil, action: (@MainActor () -> Void)? = nil) {
        let toast = Toast(message: message, systemImage: systemImage, style: style, actionTitle: actionTitle, action: action)
        current = toast
        AccessibilityNotification.Announcement(message).post()
        dismissTask?.cancel()
        // Long enough to reach an Undo button or read an error.
        let seconds: Double = action != nil || style == .error ? 6 : 3.5
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, self?.current?.id == toast.id else { return }
            self?.current = nil
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        current = nil
    }

    func runAction() {
        let action = current?.action
        dismiss()
        action?()
    }
}

/// Shows the window's current toast: at the top on iPhone and iPad, at the bottom on the Mac.
struct ToastOverlay: View {
    let toaster: Toaster

    var body: some View {
        ZStack {
            if let toast = toaster.current {
                ToastView(toast: toast, toaster: toaster)
                    .id(toast.id)
                    .transition(.move(edge: Self.edge).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25), value: toaster.current?.id)
        .padding(Self.edge == .top ? .top : .bottom, Self.edge == .top ? 6 : 22)
        .padding(.horizontal, 16)
    }

    #if os(macOS)
    static let edge: Edge = .bottom
    #else
    static let edge: Edge = .top
    #endif
}

private struct ToastView: View {
    let toast: Toaster.Toast
    let toaster: Toaster

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(iconColor)
            Text(toast.message)
                .font(.callout)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let title = toast.actionTitle {
                Button(title) { toaster.runAction() }
                    .buttonStyle(.plain)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color(Palette.accentText))
                    .accessibilityIdentifier("toast.action")
            }
            Button {
                toaster.dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
        .background(Color(Palette.card), in: Capsule())
        .overlay(Capsule().strokeBorder(Color(Palette.tertiaryText).opacity(0.35), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
        .frame(maxWidth: 520)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("toast")
    }

    private var iconColor: Color {
        switch toast.style {
        case .info: Color(Palette.accent)
        case .success: Color(Palette.green)
        case .error: Color(Palette.danger)
        }
    }
}
