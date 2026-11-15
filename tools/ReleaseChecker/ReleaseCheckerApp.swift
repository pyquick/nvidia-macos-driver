import SwiftUI

@main
struct ReleaseCheckerApp: App {
    var body: some Scene {
        Window("GeekAudio Driver Update", id: "updates") {
            ReleaseCheckerView()
        }
        .defaultSize(width: 580, height: 390)
        .windowResizability(.contentSize)
    }
}

private struct ReleaseCheckerView: View {
    private enum Result {
        case checking
        case checked(DriverRelease?, source: String)
        case failure
    }

    private struct Check: Equatable {
        var route: CheckRoute
        var includePreviews: Bool
        var attempt: Int
    }

    @AppStorage("CheckRoute") private var route = CheckRoute.automatic
    @AppStorage("IncludePreviews") private var includePreviews = false
    @State private var installed: InstalledDriver?
    @State private var result = Result.checking
    @State private var attempt = 0
    @State private var phase: DriverInstaller.Phase?
    @State private var notice: LocalizedStringKey?
    @State private var details: String?
    @State private var showDetails = false

    private let feed = ReleaseFeed()
    private let installer = DriverInstaller()

    var body: some View {
        let check = Check(route: route, includePreviews: includePreviews, attempt: attempt)
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Driver Update").font(.title2.weight(.semibold))
                Spacer()
                Text("GeekAudio · NullMoth").font(.callout).foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 12) {
                versionCard("Installed Driver", icon: "cpu", version: installed?.baseline ?? "—",
                            detail: installed?.releaseTag ?? (installed == nil
                                ? String(localized: "No driver version found on disk")
                                : String(localized: "NullMoth on disk")))
                versionCard("Available Version", icon: "arrow.down.circle", version: release.map { baselineLabel($0) } ?? "—",
                            detail: release?.tag ?? (isChecking
                                ? String(localized: "Checking…")
                                : String(localized: "No release in this channel")))
            }

            HStack(spacing: 20) {
                Picker("Connection", selection: $route) {
                    ForEach(CheckRoute.allCases) { route in Text(route.title).tag(route) }
                }
                .fixedSize()
                Spacer(minLength: 8)
                Toggle("Include Previews", isOn: $includePreviews)
                    .fixedSize()
            }
            .disabled(phase != nil)

            statusRow
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal, 12)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 9))

            HStack(spacing: 10) {
                Link("Release Notes", destination: release?.page ?? ReleaseFeed.repository.appendingPathComponent("releases"))
                Spacer()
                Button("Check for Updates") { attempt += 1 }
                    .disabled(isChecking || phase != nil)
                Button(action: beginInstall) {
                    Text(isReinstall ? LocalizedStringKey("Reinstall") : LocalizedStringKey("Download and Install"))
                }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canInstall)
            }
        }
        .padding(22)
        .frame(minWidth: 560, idealWidth: 580)
        .task(id: check) { await refresh(check) }
        .sheet(isPresented: $showDetails) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Details").font(.headline)
                ScrollView {
                    Text(details ?? "").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button("Done") { showDetails = false }.keyboardShortcut(.defaultAction)
            }
            .padding(20)
            .frame(width: 540, height: 320)
        }
    }

    private func versionCard(_ title: LocalizedStringKey, icon: String, version: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            Text(version).font(.system(.title, design: .monospaced).weight(.semibold))
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(detail)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 11))
    }

    private func baselineLabel(_ release: DriverRelease) -> String {
        let parts = release.version.base
        return (parts.last == 0 ? Array(parts.dropLast()) : parts).map(String.init).joined(separator: ".")
    }

    @ViewBuilder
    private var statusRow: some View {
        if let phase {
            ProgressView { Text(phase.title) }.controlSize(.small)
        } else if let notice {
            HStack {
                Text(notice)
                Spacer()
                if details != nil { Button("View Details") { showDetails = true } }
            }
        } else {
            switch result {
            case .checking:
                ProgressView("Checking for releases…").controlSize(.small)
            case .failure:
                HStack {
                    Label("Couldn't check for updates. Try again.", systemImage: "exclamationmark.circle")
                    Spacer()
                    Button("View Details") { showDetails = true }
                }
            case .checked(let release, let source):
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(release.map { installed?.status(for: $0) ?? String(localized: "A driver package is available") }
                            ?? String(localized: "No driver package in this channel"))
                            .fontWeight(.medium)
                        if let release, !release.offersInstaller {
                            Text("This version is available for manual installation").font(.caption).foregroundStyle(.secondary)
                        } else if !DriverInstaller.supportedSystem {
                            Text("Driver installation requires Intel macOS 15 or 26").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text(source).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var release: DriverRelease? {
        if case .checked(let release, _) = result { return release }
        return nil
    }

    private var isChecking: Bool {
        if case .checking = result { return true }
        return false
    }

    private var isReinstall: Bool {
        guard let release, let tag = installed?.releaseTag else { return false }
        return DriverVersion(tag) == release.version
    }

    private var canInstall: Bool {
        guard phase == nil, DriverInstaller.supportedSystem, let release, release.offersInstaller else { return false }
        return InstalledDriver.permitsInstallation(release)
    }

    @MainActor
    private func refresh(_ check: Check) async {
        installed = InstalledDriver.read()
        notice = nil
        details = nil
        result = .checking
        do {
            let update = try await feed.check(route: check.route, includePreviews: check.includePreviews)
            try Task.checkCancellation()
            result = .checked(update.release, source: update.source)
        } catch {
            guard !Task.isCancelled else { return }
            details = error.localizedDescription
            result = .failure
        }
    }

    @MainActor
    private func beginInstall() {
        guard canInstall, let release else { return }
        phase = .manifest
        let selectedRoute = route
        Task {
            defer { phase = nil }
            do {
                details = try await installer.install(release, route: selectedRoute) { phase = $0 }
                installed = InstalledDriver.read()
                notice = "Installation complete. Save your work and restart."
            } catch InstallError.cancelled {
                notice = "Installation canceled."
                details = nil
            } catch {
                notice = "Installation failed."
                details = error.localizedDescription
            }
        }
    }
}
