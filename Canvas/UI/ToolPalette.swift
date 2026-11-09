import SwiftUI

/// Vertical tool buttons on the left edge of the window.
struct ToolPalette: View {
    @Bindable var editor: EditorState

    var body: some View {
        VStack(spacing: 4) {
            ForEach(Array(ToolKind.paletteGroups.enumerated()), id: \.offset) { index, group in
                if index > 0 {
                    Divider().padding(.vertical, 4)
                }
                ForEach(group) { kind in
                    button(for: kind)
                }
            }
            Spacer()
        }
        .padding(6)
        .frame(width: 46)
    }

    private func button(for kind: ToolKind) -> some View {
        let selected = editor.tool == kind
        return Button {
            editor.tool = kind
        } label: {
            Image(systemName: kind.systemImage)
                .font(.system(size: 15))
                .frame(width: 32, height: 30)
                .foregroundStyle(selected ? Color.accentColor : Color.primary)
                .background(selected ? Color.accentColor.opacity(0.18) : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(kind.title) (\(kind.shortcut.uppercased()))")
    }
}
