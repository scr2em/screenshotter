import SwiftUI
import UniformTypeIdentifiers

struct HistoryView: View {
    @ObservedObject var store: HistoryStore
    @ObservedObject var settings: AppSettings
    let onOpen: (HistoryItem) -> Void

    @State private var confirmingClear = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.items.isEmpty {
                ContentUnavailableView(
                    "No Screenshots Yet",
                    systemImage: "camera.viewfinder",
                    description: Text("Press \(settings.hotKey.displayString) to capture an area of your screen.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                grid
            }
        }
        .frame(minWidth: 520, minHeight: 360)
        .confirmationDialog("Delete all screenshots?", isPresented: $confirmingClear) {
            Button("Delete All", role: .destructive) { store.clearAll() }
        } message: {
            Text("This removes \(store.items.count) screenshots from your history. This can't be undone.")
        }
    }

    private var header: some View {
        HStack {
            Text(store.items.count == 1 ? "1 screenshot" : "\(store.items.count) screenshots")
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                NSWorkspace.shared.open(store.directory)
            } label: {
                Label("Open Folder", systemImage: "folder")
            }
            Button(role: .destructive) {
                confirmingClear = true
            } label: {
                Label("Clear All…", systemImage: "trash")
            }
            .disabled(store.items.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var grid: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(sections, id: \.title) { section in
                    Text(section.title)
                        .font(.headline)
                        .padding(.leading, 2)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 210, maximum: 300), spacing: 16)], spacing: 16) {
                        ForEach(section.items) { item in
                            HistoryCell(item: item, store: store, onOpen: onOpen)
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    private var sections: [(title: String, items: [HistoryItem])] {
        let calendar = Calendar.current
        var result: [(title: String, items: [HistoryItem])] = []
        for item in store.items {
            let title: String
            if calendar.isDateInToday(item.createdAt) {
                title = "Today"
            } else if calendar.isDateInYesterday(item.createdAt) {
                title = "Yesterday"
            } else {
                title = item.createdAt.formatted(date: .complete, time: .omitted)
            }
            if result.last?.title == title {
                result[result.count - 1].items.append(item)
            } else {
                result.append((title, [item]))
            }
        }
        return result
    }
}

private struct HistoryCell: View {
    let item: HistoryItem
    let store: HistoryStore
    let onOpen: (HistoryItem) -> Void

    @State private var thumbnail: NSImage?
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.primary.opacity(0.05))
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                        .padding(10)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(height: 150)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isHovering ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: isHovering ? 2 : 1)
            )
            .overlay(alignment: .topTrailing) {
                if isHovering {
                    HStack(spacing: 4) {
                        iconButton("doc.on.doc", help: "Copy") { store.copyToClipboard(item) }
                        iconButton("pencil", help: "Edit") { onOpen(item) }
                        iconButton("folder", help: "Show in Finder") { store.revealInFinder(item) }
                        iconButton("trash", help: "Delete") { store.delete(id: item.id) }
                    }
                    .padding(8)
                }
            }

            HStack(spacing: 6) {
                Text(item.createdAt, style: .time)
                if !item.annotations.isEmpty {
                    Image(systemName: "pencil.tip.crop.circle")
                        .foregroundStyle(.secondary)
                        .help("Annotated")
                }
                Spacer()
                Text("\(item.pixelWidth) × \(item.pixelHeight)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(count: 2) { onOpen(item) }
        .onDrag {
            NSItemProvider(contentsOf: store.imageURL(for: item)) ?? NSItemProvider()
        }
        .contextMenu {
            Button("Open in Editor") { onOpen(item) }
            Button("Copy") { store.copyToClipboard(item) }
            Button("Save As…") { store.export(item) }
            Button("Show in Finder") { store.revealInFinder(item) }
            Divider()
            Button("Delete", role: .destructive) { store.delete(id: item.id) }
        }
        .task(id: item.updatedAt) {
            thumbnail = await store.thumbnail(for: item)
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
