import SwiftUI

struct AppListView: View {
    @EnvironmentObject var appState: AppState
    @State private var searchText = ""
    @State private var selection: InstalledApp.ID?
    @State private var showingDetail = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sortOrder: [KeyPathComparator<InstalledApp>] = [
        .init(\.appName, order: .forward)
    ]

    private var filteredApps: [InstalledApp] {
        let base: [InstalledApp]
        if searchText.isEmpty {
            base = appState.installedApps
        } else {
            let query = searchText.lowercased()
            base = appState.installedApps.filter {
                $0.appName.lowercased().contains(query) ||
                $0.bundleIdentifier.lowercased().contains(query)
            }
        }
        return base.sorted(using: sortOrder)
    }

    var body: some View {
        Group {
            if showingDetail, let app = appState.selectedApp {
                AppFilesView(app: app)
            } else {
                appTable
                    .searchable(text: $searchText, prompt: "Search apps")
            }
        }
        .navigationTitle(
            showingDetail
                ? (appState.selectedApp?.appName ?? String(localized: "Installed Apps"))
                : installedAppsTitle
        )
        .toolbar {
            ToolbarItemGroup {
                if showingDetail {
                    Button {
                        closeDetail()
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .keyboardShortcut("[", modifiers: .command)
                } else {
                    Button {
                        appState.loadInstalledApps()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }

                if showingDetail {
                    // ToolbarItems can't run insertion transitions on macOS 13 —
                    // keep the button mounted and fade it with the selection.
                    Button(uninstallLabel(count: appState.selectedFiles.count), role: .destructive) {
                        appState.removeSelectedFiles()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .opacity(appState.selectedFiles.isEmpty ? 0 : 1)
                    .disabled(appState.selectedFiles.isEmpty)
                    .animation(
                        reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8),
                        value: appState.selectedFiles.isEmpty
                    )
                }
            }
        }
        .onAppear {
            if let selectedApp = appState.selectedApp {
                selection = selectedApp.id
                showingDetail = true
            }
        }
        .onChange(of: appState.selectedApp) { app in
            guard let app else { return }
            selection = app.id
            showingDetail = true
        }
    }

    private var installedAppsTitle: String {
        String(format: String(localized: "Installed Apps (%lld)"), Int64(appState.installedApps.count))
    }

    private func uninstallLabel(count: Int) -> String {
        String(format: String(localized: "Uninstall (%lld files)"), Int64(count))
    }

    // MARK: - App Table (left side)

    private var appTable: some View {
        Group {
            if appState.isLoadingApps {
                VStack(spacing: 12) {
                    ProgressView(LocalizedStringKey("Loading installed apps..."))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if appState.installedApps.isEmpty {
                EmptyStateView(
                    "No Apps Found",
                    systemImage: "square.grid.2x2",
                    description: "Could not find any installed applications.",
                    action: { appState.loadInstalledApps() },
                    actionLabel: "Retry"
                )
            } else {
                Table(filteredApps, selection: $selection, sortOrder: $sortOrder) {
                    TableColumn("Application", value: \.appName) { app in
                        HStack(spacing: 8) {
                            Image(nsImage: app.icon)
                                .resizable()
                                .frame(width: 22, height: 22)
                            Text(app.appName)
                        }
                    }
                    .width(min: 150)

                    TableColumn("Size", value: \.size) { app in
                        Text(app.formattedSize)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .width(ideal: 70)
                }
                .contextMenu(forSelectionType: InstalledApp.ID.self) { ids in
                    if let id = ids.first {
                        Button("Open") {
                            openApp(id: id)
                        }
                    }
                } primaryAction: { ids in
                    guard ids.count == 1, let id = ids.first else { return }
                    openApp(id: id)
                }
            }
        }
    }

    private func openApp(id: InstalledApp.ID) {
        guard let app = appState.installedApps.first(where: { $0.id == id }) else {
            return
        }
        selection = id
        showingDetail = true
        if appState.selectedApp?.id != app.id || appState.discoveredFiles.isEmpty {
            appState.selectedApp = app
            appState.scanForAppFiles(app)
        }
    }

    private func closeDetail() {
        showingDetail = false
        selection = appState.selectedApp?.id
        appState.cancelAppFileScan()
        appState.selectedApp = nil
    }
}
