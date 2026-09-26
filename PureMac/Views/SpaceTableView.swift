import SwiftUI

struct SpaceTableRowCache {
    enum ItemSortColumn: Hashable { case name, size, share }
    struct VisibleRow: Identifiable {
        let item: SpaceTableItem
        let depth: Int
        var id: String { item.id }
    }
    struct Key: Equatable {
        let items: [SpaceTableItem]
        let revision: Int
        let expanded: Set<String>
        let column: ItemSortColumn
        let ascending: Bool
    }
    private(set) var rows: [VisibleRow] = []
    private(set) var rebuildCount = 0
    private var key: Key?

    mutating func update(_ newKey: Key, children: (SpaceTableItem) -> [SpaceTableItem]?) {
        guard key != newKey else { return }
        var output: [VisibleRow] = []
        output.reserveCapacity(newKey.items.count)
        func append(_ items: [SpaceTableItem], depth: Int) {
            for item in Self.sorted(items, column: newKey.column, ascending: newKey.ascending) {
                output.append(VisibleRow(item: item, depth: depth))
                if item.isDirectory, newKey.expanded.contains(item.path), let nested = children(item) {
                    append(nested, depth: depth + 1)
                }
            }
        }
        append(newKey.items, depth: 0)
        rows = output
        key = newKey
        rebuildCount += 1
    }

    static func sorted(_ items: [SpaceTableItem], column: ItemSortColumn, ascending: Bool) -> [SpaceTableItem] {
        items.sorted { left, right in
            let primaryOrder: ComparisonResult
            switch column {
            case .name:
                primaryOrder = left.name.localizedStandardCompare(right.name)
            case .size, .share:
                if left.size < right.size {
                    primaryOrder = .orderedAscending
                } else if left.size > right.size {
                    primaryOrder = .orderedDescending
                } else {
                    primaryOrder = .orderedSame
                }
            }

            if primaryOrder == .orderedSame {
                return left.name.localizedStandardCompare(right.name) == .orderedAscending
            }
            return ascending
                ? primaryOrder == .orderedAscending
                : primaryOrder == .orderedDescending
        }
    }

}


struct SpaceTableView: View {
    private typealias ItemSortColumn = SpaceTableRowCache.ItemSortColumn
    @ObservedObject var viewModel: SpaceTableViewModel
    @State private var rowCache = SpaceTableRowCache()
    private var visibleRows: [SpaceTableRowCache.VisibleRow] { rowCache.rows }
    @State private var showTrashConfirmation = false
    @State private var expandedPaths: Set<String> = []
    @State private var rowSelection: String?
    @State private var volumeSelection: SpaceTableVolume.ID?
    @State private var showingVolume = false
    @State private var itemSortColumn: ItemSortColumn = .size
    @State private var itemSortAscending = false
    @State private var volumeSortOrder: [KeyPathComparator<SpaceTableVolume>] = [
        .init(\.name, order: .forward)
    ]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let sizeColumnWidth: CGFloat = 152
    private static let shareColumnWidth: CGFloat = 70

    var body: some View {
        content
            .navigationTitle(
                showingVolume
                    ? (viewModel.selectedVolume?.name ?? String(localized: "Space Table"))
                    : spaceTableTitle
            )
            .toolbar { toolbarContent }
            .onAppear {
                rebuildRows()
                viewModel.loadVolumes()
                if let selectedVolume = viewModel.selectedVolume {
                    volumeSelection = selectedVolume.id
                    showingVolume = true
                    viewModel.resumeBackgroundIndexing()
                }
            }
            .onChange(of: viewModel.items) { _ in rebuildRows() }
            .onChange(of: viewModel.indexingRevision) { _ in rebuildRows() }
            .onChange(of: expandedPaths) { _ in rebuildRows() }
            .onChange(of: itemSortColumn) { _ in rebuildRows() }
            .onChange(of: itemSortAscending) { _ in rebuildRows() }
            .onChange(of: viewModel.selectedVolume) { volume in
                if volume == nil {
                    showingVolume = false
                }
            }
            .alert(
                "Move selected items to Trash?",
                isPresented: $showTrashConfirmation
            ) {
                Button("Cancel", role: .cancel) {}
                Button("Move to Trash", role: .destructive) {
                    viewModel.moveSelectedItemsToTrash()
                }
            } message: {
                Text(
                    "\(viewModel.selectedCount) selected items (\(formatted(viewModel.selectedSize))) will be moved to the Trash."
                )
            }
            .alert(
                "Some items could not be moved",
                isPresented: Binding(
                    get: { viewModel.deletionError != nil },
                    set: { if !$0 { viewModel.clearDeletionError() } }
                )
            ) {
                Button("OK", role: .cancel) {
                    viewModel.clearDeletionError()
                }
            } message: {
                Text(viewModel.deletionError ?? "")
            }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if showingVolume {
            ToolbarItem(placement: .navigation) {
                Button {
                    if viewModel.navigationPath.count > 1 {
                        viewModel.navigateBack()
                    } else {
                        closeVolume()
                    }
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .disabled(viewModel.state.isScanning)
                .keyboardShortcut("[", modifiers: .command)
            }

            ToolbarItemGroup {
                if viewModel.state.isScanning {
                    Button("Cancel") { viewModel.cancelScan() }
                } else {
                    Button {
                        viewModel.scanCurrentLocation()
                    } label: {
                        Label("Rescan", systemImage: "viewfinder")
                    }
                }
            }
        } else {
            ToolbarItemGroup {
                Button {
                    viewModel.loadVolumes()
                } label: {
                    Label("Refresh Volumes", systemImage: "arrow.clockwise")
                }
            }
        }
    }

    private var spaceTableTitle: String {
        String(
            format: String(localized: "Space Table (%lld)"),
            Int64(viewModel.volumes.count)
        )
    }

    @ViewBuilder
    private var content: some View {
        if showingVolume {
            volumeContents
        } else {
            volumeTable
        }
    }

    @ViewBuilder
    private var volumeTable: some View {
        if viewModel.volumes.isEmpty {
            EmptyStateView(
                "No Volumes Found",
                systemImage: "externaldrive",
                description: "PureMac could not find a browsable storage volume.",
                action: { viewModel.loadVolumes() },
                actionLabel: "Refresh",
                tint: Tint.cyan
            )
        } else {
            Table(sortedVolumes, selection: $volumeSelection, sortOrder: $volumeSortOrder) {
                TableColumn("Volume", value: \.name) { volume in
                    HStack(spacing: 8) {
                        Image(systemName: volume.path == "/" ? "internaldrive.fill" : "externaldrive.fill")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(Tint.cyan)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(volume.name)
                            Text(volume.path)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                .width(min: 180)

                TableColumn("Used", value: \.usedSize) { volume in
                    Text(formatted(volume.usedSize))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .width(min: 110, ideal: 130)

                TableColumn("Available", value: \.availableSize) { volume in
                    Text(formatted(volume.availableSize))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .width(min: 110, ideal: 130)

                TableColumn("Capacity", value: \.totalSize) { volume in
                    Text(formatted(volume.totalSize))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .width(min: 110, ideal: 130)

                TableColumn("Usage", value: \.usageFraction) { volume in
                    HStack(spacing: 8) {
                        ProgressView(value: volume.usageFraction)
                            .progressViewStyle(.linear)
                        Text(
                            volume.usageFraction.formatted(
                                .percent.precision(.fractionLength(0))
                            )
                        )
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .trailing)
                    }
                }
                .width(min: 120, ideal: 160)
            }
            .contextMenu(forSelectionType: SpaceTableVolume.ID.self) { ids in
                if let id = ids.first {
                    Button("Open") { openVolume(id: id) }
                }
            } primaryAction: { ids in
                guard ids.count == 1, let id = ids.first else { return }
                openVolume(id: id)
            }
        }
    }

    @ViewBuilder
    private var volumeContents: some View {
        switch viewModel.state {
        case .idle:
            EmptyStateView(
                "Volume Not Scanned",
                systemImage: "externaldrive",
                description: "Open this volume to calculate its folders and files.",
                action: { viewModel.scanSelectedVolume() },
                actionLabel: "Calculate",
                tint: Tint.cyan
            )
        case .scanning(let path, let discoveredBytes):
            scanningView(path: path, discoveredBytes: discoveredBytes)
        case .complete:
            if viewModel.items.isEmpty {
                EmptyStateView(
                    "Nothing to show",
                    systemImage: "folder",
                    description: "This location is empty or PureMac could not read its contents.",
                    action: { viewModel.scanCurrentLocation() },
                    actionLabel: "Scan Again",
                    tint: Tint.cyan
                )
            } else {
                resultsView
            }
        case .failed(let message):
            EmptyStateView(
                "Couldn't scan this location",
                systemImage: "exclamationmark.triangle",
                description: LocalizedStringKey(message),
                action: { viewModel.scanCurrentLocation() },
                actionLabel: "Try Again",
                tint: Tint.orange
            )
        }
    }

    private func openVolume(id: SpaceTableVolume.ID) {
        guard let volume = viewModel.volumes.first(where: { $0.id == id }) else {
            return
        }
        volumeSelection = id
        expandedPaths.removeAll()
        showingVolume = true
        viewModel.openVolume(volume)
    }

    private func closeVolume() {
        volumeSelection = viewModel.selectedVolume?.id
        expandedPaths.removeAll()
        showingVolume = false
        viewModel.closeVolume()
    }

    private func scanningView(path: String, discoveredBytes: Int64) -> some View {
        VStack(spacing: 12) {
            ProgressView(LocalizedStringKey("Mapping your storage…"))
                .progressViewStyle(.linear)
                .frame(maxWidth: 300)

            Text(path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Text(ByteCountFormatter.string(fromByteCount: discoveredBytes, countStyle: .file))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .contentTransition(reduceMotion ? .identity : .numericText())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var resultsView: some View {
        VStack(spacing: 0) {
            resultHeader
            Divider()
            outlineHeader
            Divider()
            itemOutline

            if viewModel.selectedCount > 0 {
                selectionActionBar
            }
        }
    }

    private var outlineHeader: some View {
        HStack(spacing: ExplorerControlColumnMetrics.spacing) {
            ExplorerControlColumnHeader()
            ExplorerControlColumnHeader()
            sortableHeader("Name", column: .name)
                .frame(maxWidth: .infinity, alignment: .leading)
            sortableHeader("Size", column: .size)
                .frame(width: Self.sizeColumnWidth, alignment: .trailing)
            sortableHeader("Share", column: .share)
                .frame(width: Self.shareColumnWidth, alignment: .trailing)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    private var itemOutline: some View {
        List(selection: $rowSelection) {
            ForEach(visibleRows) { row in
                spaceTableRow(row.item, depth: row.depth)
            }
        }
        .listStyle(.inset)
    }

    private var sortedVolumes: [SpaceTableVolume] {
        viewModel.volumes.sorted(using: volumeSortOrder)
    }

    private func rebuildRows() {
        rowCache.update(.init(items: viewModel.items, revision: viewModel.indexingRevision,
            expanded: expandedPaths, column: itemSortColumn, ascending: itemSortAscending),
            children: { viewModel.indexedChildren(of: $0) })
    }

    private func spaceTableRow(_ item: SpaceTableItem, depth: Int) -> some View {
        HStack(spacing: ExplorerControlColumnMetrics.spacing) {
            ExplorerSelectionColumn(
                isSelected: Binding(
                    get: { viewModel.isSelected(item) },
                    set: { viewModel.setSelected(item, selected: $0) }
                ),
                isEnabled: viewModel.isDeletable(item),
                tint: Tint.cyan,
                help: "Select for Trash",
                disabledHelp: "Protected system item"
            )

            ExplorerDisclosureColumn(
                isExpandable: item.isDirectory,
                isExpanded: expandedPaths.contains(item.path),
                isLoading: expandedPaths.contains(item.path) && !viewModel.isIndexed(item.path),
                action: { toggleExpansion(of: item) }
            )

            HStack(spacing: 10) {
                Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                    .foregroundStyle(item.isDirectory ? Tint.cyan : Color.secondary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name)
                        .lineLimit(1)
                    Text(item.path)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.leading, CGFloat(depth) * 16)
            .frame(maxWidth: .infinity, alignment: .leading)

            Group {
                if viewModel.isSizePending(item) {
                    HStack(spacing: 5) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("Calculating…")
                            .lineLimit(1)
                    }
                    .foregroundStyle(.secondary)
                } else {
                    Text(item.formattedSize)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: Self.sizeColumnWidth, alignment: .trailing)

            Text(percentText(for: item))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: Self.shareColumnWidth, alignment: .trailing)
        }
        .contentShape(Rectangle())
        .tag(item.path)
        .simultaneousGesture(
            TapGesture().onEnded {
                rowSelection = item.path
            }
        )
        .onTapGesture(count: 2) {
            if item.isDirectory {
                open(item)
            } else {
                viewModel.revealInFinder(item)
            }
        }
        .contextMenu {
            if item.isDirectory {
                Button("Open") { open(item) }
            }
            Button("Reveal in Finder") { viewModel.revealInFinder(item) }
            if viewModel.isDeletable(item) {
                Divider()
                Button("Select for Trash") {
                    viewModel.setSelected(item, selected: true)
                }
            }
        }
        .padding(.vertical, 2)
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
    }

    private func toggleExpansion(of item: SpaceTableItem) {
        guard item.isDirectory else { return }
        if expandedPaths.contains(item.path) {
            expandedPaths.remove(item.path)
        } else {
            expandedPaths.insert(item.path)
            viewModel.prioritizeIndexing(item)
        }
    }

    private func sortableHeader(
        _ title: LocalizedStringKey,
        column: ItemSortColumn
    ) -> some View {
        Button {
            if itemSortColumn == column {
                itemSortAscending.toggle()
            } else {
                itemSortColumn = column
                itemSortAscending = column == .name
            }
        } label: {
            HStack(spacing: 4) {
                Text(title)
                if itemSortColumn == column {
                    Image(systemName: itemSortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
            }
            .frame(
                maxWidth: .infinity,
                alignment: column == .name ? .leading : .trailing
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Click to sort; click again to reverse the order")
    }

    private var selectionActionBar: some View {
        HStack(spacing: 12) {
            Button("Select All") {
                viewModel.selectCurrentItems()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button("Deselect All") {
                viewModel.deselectAll()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Spacer()

            Button(role: .destructive) {
                showTrashConfirmation = true
            } label: {
                Text(
                    "Move \(viewModel.selectedCount) items (\(formatted(viewModel.selectedSize))) to Trash"
                )
            }
            .buttonStyle(
                GlowProminentButtonStyle(
                    tint: Tint.red,
                    gradient: TintGradient.destructive
                )
            )
            .disabled(viewModel.isMovingToTrash)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider().opacity(0.6)
        }
    }

    private var resultHeader: some View {
        HStack(spacing: 8) {
            breadcrumb

            Spacer()

            if viewModel.isBackgroundIndexing {
                HStack(spacing: 5) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("\(viewModel.indexedFolderCount) folders ready")
                        .monospacedDigit()
                }
                .foregroundStyle(.secondary)
                .help("Space Table is indexing folders in the background")
            }

            if viewModel.unreadableItemCount > 0 {
                Label(
                    String(
                        format: String(localized: "%lld unreadable"),
                        Int64(viewModel.unreadableItemCount)
                    ),
                    systemImage: "lock.fill"
                )
                .foregroundStyle(.secondary)
                .help("Grant Full Disk Access for more complete results")
            }

            if viewModel.unrepresentedSystemSize > 0 {
                Label {
                    Text(verbatim: "\(formatted(viewModel.unrepresentedSystemSize)) system data")
                } icon: {
                    Image(systemName: "internaldrive.fill")
                }
                .foregroundStyle(.secondary)
                .help(
                    Text(
                        verbatim: "APFS snapshots, purgeable storage, and protected system data are not ordinary files or folders."
                    )
                )
            }

            Text(itemsSummary)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(12)
    }

    private var breadcrumb: some View {
        HStack(spacing: 5) {
            ForEach(Array(viewModel.navigationPath.enumerated()), id: \.element) { index, path in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Button(pathLabel(path)) {
                    viewModel.navigate(to: path)
                }
                .buttonStyle(.plain)
                .fontWeight(index == viewModel.navigationPath.count - 1 ? .semibold : .regular)
            }
        }
        .lineLimit(1)
    }

    private func open(_ item: SpaceTableItem) {
        if item.isDirectory {
            viewModel.open(item)
        } else {
            viewModel.revealInFinder(item)
        }
    }

    private var itemsSummary: String {
        "\(viewModel.items.count) items · \(formatted(viewModel.scannedSize))"
    }

    private func percentText(for item: SpaceTableItem) -> String {
        let percentage = Double(item.size) / Double(max(1, viewModel.scannedSize))
        return percentage.formatted(.percent.precision(.fractionLength(percentage < 0.01 ? 1 : 0)))
    }

    private func pathLabel(_ path: String) -> String {
        guard path != "/" else { return viewModel.selectedVolume?.name ?? "/" }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private func formatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
