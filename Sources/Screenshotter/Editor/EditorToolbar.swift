import SwiftUI

struct EditorActions {
    var copy: () -> Void
    var save: () -> Void
    var done: () -> Void
    var discard: () -> Void
}

struct EditorToolbar: View {
    @ObservedObject var document: EditorDocument
    let actions: EditorActions

    @State private var showingColors = false
    @State private var copiedFlash = false

    var body: some View {
        HStack(spacing: 10) {
            toolPicker
            divider
            colorButton
            sizePicker
            Spacer(minLength: 8)
            undoRedo
            divider
            Button(action: actions.discard) {
                Image(systemName: "trash")
            }
            .help("Delete this screenshot")
            Button {
                actions.copy()
                copiedFlash = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copiedFlash = false }
            } label: {
                Label(copiedFlash ? "Copied" : "Copy", systemImage: copiedFlash ? "checkmark" : "doc.on.doc")
                    .frame(minWidth: 62)
            }
            .help("Copy to clipboard (⌘C)")
            Button(action: actions.save) {
                Image(systemName: "square.and.arrow.down")
            }
            .help("Save as… (⌘S)")
            Button(action: actions.done) {
                Text("Done").frame(minWidth: 44)
            }
            .buttonStyle(.borderedProminent)
            .help("Copy, save to history and close (↩)")
        }
        .controlSize(.regular)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var divider: some View {
        Divider().frame(height: 20)
    }

    private var toolPicker: some View {
        HStack(spacing: 2) {
            ForEach(AnnotationTool.allCases) { tool in
                let isSelected = document.tool == tool
                Button {
                    document.tool = tool
                } label: {
                    Image(systemName: tool.symbol)
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 28, height: 24)
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(isSelected ? Color.accentColor : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(tool.title) (\(String(tool.shortcut).uppercased()))")
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
    }

    private var colorButton: some View {
        Button {
            showingColors.toggle()
        } label: {
            Circle()
                .fill(Color(nsColor: document.color.nsColor))
                .frame(width: 20, height: 20)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 1))
                .padding(3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Color (1–9)")
        .popover(isPresented: $showingColors, arrowEdge: .bottom) {
            ColorPalette(color: $document.color) { showingColors = false }
        }
    }

    private var sizePicker: some View {
        HStack(spacing: 2) {
            ForEach(StrokeSize.allCases) { size in
                let isSelected = document.size == size
                Button {
                    document.size = size
                } label: {
                    Circle()
                        .fill(isSelected ? Color.white : Color.primary)
                        .frame(width: [5, 8, 12][size.rawValue], height: [5, 8, 12][size.rawValue])
                        .frame(width: 26, height: 24)
                        .background(RoundedRectangle(cornerRadius: 6).fill(isSelected ? Color.accentColor : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(size.title) line / text")
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
    }

    private var undoRedo: some View {
        HStack(spacing: 4) {
            Button { document.undoManager.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!document.undoManager.canUndo)
                .help("Undo (⌘Z)")
            Button { document.undoManager.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!document.undoManager.canRedo)
                .help("Redo (⇧⌘Z)")
        }
    }
}

private struct ColorPalette: View {
    @Binding var color: RGBAColor
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 8), count: 5), spacing: 8) {
                ForEach(Array(RGBAColor.palette.enumerated()), id: \.offset) { index, swatch in
                    Button {
                        color = swatch
                        dismiss()
                    } label: {
                        Circle()
                            .fill(Color(nsColor: swatch.nsColor))
                            .frame(width: 24, height: 24)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 1))
                            .overlay(
                                Circle()
                                    .strokeBorder(Color.accentColor, lineWidth: 2)
                                    .padding(-4)
                                    .opacity(swatch == color ? 1 : 0)
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Shortcut: \(index + 1)")
                }
            }
            Divider()
            ColorPicker("Custom color", selection: Binding(
                get: { Color(nsColor: color.nsColor) },
                set: { color = RGBAColor(NSColor($0)) }
            ))
        }
        .padding(14)
    }
}
