import SwiftUI

/// Shared leading columns for browsable, selectable file lists.
///
/// Keeping selection and disclosure in fixed-width columns prevents nested
/// content from shifting either control as rows expand.
enum ExplorerControlColumnMetrics {
    static let width: CGFloat = 18
    static let spacing: CGFloat = 4
}

struct ExplorerControlColumnHeader: View {
    var body: some View {
        Color.clear
            .frame(width: ExplorerControlColumnMetrics.width, height: 1)
            .accessibilityHidden(true)
    }
}

struct ExplorerSelectionColumn: View {
    @Binding var isSelected: Bool
    var isEnabled = true
    var tint = Tint.blue
    var help: LocalizedStringKey = "Select"
    var disabledHelp: LocalizedStringKey = "Selection unavailable"

    var body: some View {
        Toggle("", isOn: $isSelected)
            .toggleStyle(AnimatedCheckboxStyle(tint: tint))
            .labelsHidden()
            .disabled(!isEnabled)
            .help(isEnabled ? help : disabledHelp)
            .frame(width: ExplorerControlColumnMetrics.width)
    }
}

struct ExplorerDisclosureColumn: View {
    var isExpandable = false
    var isExpanded = false
    var isLoading = false
    var action: () -> Void = {}

    var body: some View {
        Group {
            if isExpandable {
                Button(action: action) {
                    Group {
                        if isLoading {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        }
                    }
                    .frame(width: 14, height: 16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isLoading)
                .help(
                    isLoading
                        ? "Calculating folder sizes…"
                        : (isExpanded ? "Collapse" : "Expand")
                )
                .accessibilityLabel(
                    isLoading
                        ? "Calculating folder sizes"
                        : (isExpanded ? "Collapse" : "Expand")
                )
            } else {
                Color.clear
                    .frame(width: 14, height: 16)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: ExplorerControlColumnMetrics.width)
    }
}
