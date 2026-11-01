import AppKit
import PortCore

extension StudioModel {
    var miiLibraryURL: URL { supportURL.appendingPathComponent("Miis/library.dmii") }
    var selectedMiiDatabaseURL: URL? { personalMiis.count > 0 ? miiLibraryURL : nil }

    func reloadMiis() async {
        guard !repositoryPath.isEmpty, !isBusy, !isLoadingMiis else { return }
        isLoadingMiis = true
        defer { isLoadingMiis = false }
        do {
            personalMiis = try await MiiLibrary.load(databaseURL: miiLibraryURL,
                repositoryURL: URL(fileURLWithPath: repositoryPath), pythonURL: pythonURL, using: miiRunner)
            miiLibraryError = nil
        } catch is CancellationError {
            // Leaving the page cancels its read, not the existing library.
        } catch {
            miiLibraryError = t("The Mii library could not be read. Import valid personal Mii data or update Studio.")
        }
    }

    func choosePersonalMiis() {
        guard !isBusy, !isLoadingMiis, !repositoryPath.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.title = t("Choose personal Mii data exported from your Switch")
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        // NFDB exports have no standard extension. The content validator,
        // rather than a filename filter, decides which formats are accepted.
        guard panel.runModal() == .OK, let source = panel.url else { return }
        failure = nil; miiLibraryError = nil; completedURL = nil
        isBusy = true; status = "Importing personal Miis"
        stageName = status; stepName = ""; stageIndex = 0; stageTotal = 0; progress = nil
        currentTask = Task { [self] in
            defer { isBusy = false; currentTask = nil }
            do {
                personalMiis = try await MiiLibrary.importRecords(from: source, databaseURL: miiLibraryURL,
                    repositoryURL: URL(fileURLWithPath: repositoryPath), pythonURL: pythonURL, using: runner)
                status = "Personal Miis imported"; stageName = status; progress = 1
                completedURL = miiLibraryURL.deletingLastPathComponent()
                appendLog("Personal Mii library validated: \(personalMiis.count) records; \(personalMiis.imported) added, \(personalMiis.updated) updated, \(personalMiis.duplicates) unchanged.")
            } catch is CancellationError {
                status = "Cancelled"
            } catch {
                status = "Mii import failed"
                miiLibraryError = t("Choose a .charinfo, StoreData or decrypted NFDB export. Encrypted saves and NFIF files are not supported.")
                failure = miiLibraryError
                // Validator errors contain no personal record bytes or names.
                appendLog(error.localizedDescription)
            }
        }
    }
}
