import SwiftUI
import PortCore

struct SavedGamesView: View {
    @Bindable var model: StudioModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(t("Native Mac ports")).font(.headline)
                Spacer()
                Button(t("Refresh")) { Task { await model.reloadSavePorts() } }
                    .buttonStyle(QuietButtonStyle()).disabled(model.isLoadingSavePorts || model.isManagingSaves)
            }
            if model.isLoadingSavePorts {
                ProgressView(t("Finding installed ports…"))
            } else if model.savePorts.isEmpty {
                StudioPanel {
                    Text(t("No native ports found in Applications. Install a Mac port first."))
                        .foregroundStyle(StudioStyle.muted).frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                StudioPanel {
                    VStack(alignment: .leading, spacing: 16) {
                        Picker(t("Game"), selection: $model.selectedSavePortID) {
                            ForEach(model.savePorts) { port in Text(verbatim: port.name).tag(port.id) }
                        }
                        .onChange(of: model.selectedSavePortID) {
                            model.selectedSaveSlot = .primary
                            model.saveArchiveMessage = nil; model.saveArchiveError = nil; model.lastSaveBackupURL = nil
                        }
                        if let port = model.selectedSavePort {
                            Text(verbatim: port.titleID).font(.system(.caption, design: .monospaced)).foregroundStyle(StudioStyle.muted)
                            Picker(t("Save type"), selection: $model.selectedSaveSlot) {
                                Text(t("Main save")).tag(SaveSlot.primary)
                                Text(t("Device save")).tag(SaveSlot.device)
                            }
                            Text((port.stateURL.appendingPathComponent(model.selectedSaveSlot.rawValue).path as NSString).abbreviatingWithTildeInPath)
                                .font(.caption).foregroundStyle(StudioStyle.muted).textSelection(.enabled)
                            ViewThatFits(in: .horizontal) {
                                HStack { archiveButtons }
                                VStack(alignment: .leading, spacing: 10) { archiveButtons }
                            }
                            Divider()
                            HStack {
                                Button(t("Open save folder")) { model.openSelectedSaveFolder() }
                                Button(t("Open backups")) { model.openSaveBackups() }
                            }.buttonStyle(QuietButtonStyle())
                            Text(t("JKSV ZIP files contain save files at the root. Main save also covers games with device-only saves. Choose Device save only for games that keep an additional, separate device save. Previous saves are kept in Backups.")).font(.footnote).foregroundStyle(StudioStyle.muted)
                            Text(t("Close the game before managing its saves."))
                                .font(.footnote).foregroundStyle(StudioStyle.muted)
                        }
                    }.disabled(model.isManagingSaves || model.isBusy)
                }
            }
            if model.isManagingSaves { ProgressView(t("Processing saved game…")) }
            if let message = model.saveArchiveMessage {
                Label(message, systemImage: "checkmark.circle").foregroundStyle(StudioStyle.signal)
            }
            if let error = model.saveArchiveError {
                Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
        }
        .task { await model.reloadSavePorts() }
    }

    @ViewBuilder private var archiveButtons: some View {
        Button { model.chooseSaveImport() } label: { Label(t("Import JKSV ZIP"), systemImage: "square.and.arrow.down") }
            .buttonStyle(PrimaryButtonStyle())
        Button { model.chooseSaveExport() } label: { Label(t("Export JKSV ZIP"), systemImage: "square.and.arrow.up") }
            .buttonStyle(QuietButtonStyle())
    }
}
