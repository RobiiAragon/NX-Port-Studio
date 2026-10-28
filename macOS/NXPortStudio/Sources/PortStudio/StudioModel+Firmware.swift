import AppKit
import PortCore
import UniformTypeIdentifiers

extension StudioModel {
    var firmwareLibraryURL: URL { supportURL.appendingPathComponent("Firmware", isDirectory: true) }
    var selectedFirmware: ImportedFirmware? { importedFirmware.first { $0.directoryURL.path == selectedFirmwarePath } }
    var selectedSystemDataURL: URL? {
        selectedFirmwarePath.isEmpty ? nil : URL(fileURLWithPath: selectedFirmwarePath, isDirectory: true).appendingPathComponent("system_data", isDirectory: true)
    }

    func reloadFirmware() { importedFirmware = FirmwareLibrary.installed(in: firmwareLibraryURL) }

    func chooseFirmwareZIP() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = t("Choose a firmware ZIP from your Switch")
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importFirmware(from: url)
    }

    func chooseFirmwareFolder() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = t("Choose a firmware folder from your Switch")
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importFirmware(from: url)
    }

    func importRyujinxFirmware() {
        let source = FirmwareLibrary.ryujinxSourceURL
        guard FileManager.default.fileExists(atPath: source.path) else {
            failure = t("No installed Ryujinx firmware was found. Choose a firmware folder or ZIP instead.")
            return
        }
        importFirmware(from: source)
    }

    func importFirmware(from source: URL) {
        guard !isBusy else { return }
        guard !keysPath.isEmpty else {
            failure = t("Select prod.keys from your console before importing firmware.")
            return
        }
        guard !repositoryPath.isEmpty else { failure = t("Prepare the engine before importing firmware."); return }
        failure = nil; completedURL = nil; page = .firmware
        stageName = "Importing firmware resources"; stepName = ""; stageIndex = 0; stageTotal = 0; progress = nil
        isBusy = true; status = "Importing firmware resources"
        appendLog("Importing local firmware resources from \(source.lastPathComponent).")
        let runID = UUID(); operationID = runID
        let keys = URL(fileURLWithPath: keysPath), repository = URL(fileURLWithPath: repositoryPath)
        let library = firmwareLibraryURL, tools = supportURL.appendingPathComponent("Tools", isDirectory: true)
        currentTask = Task { [self] in
            do {
                let imported = try await FirmwareLibrary.importResources(sourceURL: source, keysURL: keys, repositoryURL: repository,
                    libraryURL: library, toolsURL: tools, using: runner) { [weak self] line in
                        Task { @MainActor in
                            guard let self, self.operationID == runID else { return }
                            self.receive(line)
                        }
                    }
                try Task.checkCancellation()
                reloadFirmware(); selectedFirmwarePath = imported.directoryURL.path
                status = "Firmware resources imported"; stageName = "Firmware resources imported"; progress = 1
                completedURL = imported.directoryURL
                appendLog("Validated firmware \(imported.catalog.firmwareVersion): \(imported.catalog.resources.count) system data archives.")
            } catch is CancellationError {
                status = "Cancelled"; appendLog("Firmware import cancelled; previous imports were preserved.")
            } catch {
                status = "Firmware import failed"; failure = t("Firmware import failed. Review Activity; prod.keys must support the firmware version you selected.")
                appendLog(error.localizedDescription)
            }
            operationID = UUID(); isBusy = false; currentTask = nil
        }
    }
}
