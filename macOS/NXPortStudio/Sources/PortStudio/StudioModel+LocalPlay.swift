import Foundation
import PortCore

extension StudioModel {
    func startLocalDiscoveryRelay() {
        guard !isStartingLocalRelay, !isStoppingLocalRelay, !localRelaySnapshot.isRunning else { return }
        localRelayOperationID = UUID()
        let operation = localRelayOperationID
        isStartingLocalRelay = true
        localRelayError = nil
        localRelayTask = Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await localRelayService.start()
                guard !Task.isCancelled, operation == localRelayOperationID else { return }
                localRelaySnapshot = snapshot
                startLocalRelayPolling()
            } catch is CancellationError {
                // The stop operation owns cleanup and the subsequent state.
            } catch {
                guard operation == localRelayOperationID else { return }
                localRelayError = localRelayMessage(error)
            }
            guard operation == localRelayOperationID else { return }
            isStartingLocalRelay = false
            localRelayTask = nil
        }
    }

    func stopLocalDiscoveryRelay() {
        guard !isStoppingLocalRelay else { return }
        localRelayOperationID = UUID()
        let operation = localRelayOperationID
        let pendingStart = localRelayTask
        pendingStart?.cancel()
        localRelayTask = nil
        localRelayPollTask?.cancel()
        localRelayPollTask = nil
        isStartingLocalRelay = false
        isStoppingLocalRelay = true
        localRelayTask = Task { [weak self] in
            guard let self else { return }
            // A cancelled setup must finish before stop and any later restart.
            // This also protects injected asynchronous implementations.
            await pendingStart?.value
            let snapshot = await localRelayService.stop()
            guard operation == localRelayOperationID else { return }
            localRelaySnapshot = snapshot
            localRelayError = nil
            isStoppingLocalRelay = false
            localRelayTask = nil
        }
    }

    func refreshLocalDiscoveryRelay() async {
        guard !isStartingLocalRelay, !isStoppingLocalRelay else { return }
        let operation = localRelayOperationID
        let snapshot = await localRelayService.snapshot()
        guard operation == localRelayOperationID, !isStartingLocalRelay, !isStoppingLocalRelay else { return }
        localRelaySnapshot = snapshot
        if let error = snapshot.failure { localRelayError = localRelayMessage(error) }
        if snapshot.isRunning { startLocalRelayPolling() }
    }

    private func startLocalRelayPolling() {
        localRelayPollTask?.cancel()
        localRelayPollTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self else { return }
                let operation = localRelayOperationID
                let snapshot = await localRelayService.snapshot()
                guard !Task.isCancelled, operation == localRelayOperationID else { return }
                localRelaySnapshot = snapshot
                if let error = snapshot.failure { localRelayError = localRelayMessage(error) }
                if !snapshot.isRunning { return }
            }
        }
    }

    private func localRelayMessage(_ error: Error) -> String {
        guard let error = error as? LocalDiscoveryRelayError else { return t("The local discovery bridge could not be started.") }
        switch error {
        case .system(let code):
            return String(format: t("The local discovery bridge encountered a network error (%d)."), code)
        default: return t(error.localizedDescription)
        }
    }
}
