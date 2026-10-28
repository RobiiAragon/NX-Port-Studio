import SwiftUI
import PortCore

struct LocalPlayView: View {
    @Bindable var model: StudioModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            StudioPanel {
                VStack(alignment: .leading, spacing: 18) {
                    Label(t("iPhone room discovery bridge"), systemImage: "iphone.and.arrow.forward")
                        .font(.system(size: 17, weight: .medium))
                    Text(t("Let a Switch discover rooms hosted by an iPhone or iPad through this Mac. No IP address is needed."))
                        .foregroundStyle(StudioStyle.muted).fixedSize(horizontal: false, vertical: true)
                    HStack(alignment: .center, spacing: 16) {
                        VStack(alignment: .leading, spacing: 5) {
                            Label(t(stateTitle), systemImage: model.localRelaySnapshot.isRunning ? "antenna.radiowaves.left.and.right" : "power")
                                .fontWeight(.medium)
                            Text(t("Keep Studio open and all devices on the same local network."))
                                .font(.system(size: 12)).foregroundStyle(StudioStyle.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        if model.isStartingLocalRelay || model.isStoppingLocalRelay { ProgressView().controlSize(.small) }
                        if model.isStartingLocalRelay {
                            Button(t("Cancel")) { model.stopLocalDiscoveryRelay() }.buttonStyle(QuietButtonStyle())
                        } else if model.localRelaySnapshot.isRunning || model.isStoppingLocalRelay {
                            Button(t("Stop bridge")) { model.stopLocalDiscoveryRelay() }
                                .buttonStyle(QuietButtonStyle()).disabled(model.isStoppingLocalRelay)
                        } else {
                            Button(t("Start bridge")) { model.startLocalDiscoveryRelay() }.buttonStyle(PrimaryButtonStyle())
                        }
                    }
                    if let error = model.localRelayError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 12)).foregroundStyle(StudioStyle.signal)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if model.localRelaySnapshot.isRunning || model.localRelaySnapshot.queriesReceived > 0 {
                        RelayTrafficView(snapshot: model.localRelaySnapshot)
                    }
                    Text(t("Only room discovery is relayed. Gameplay connects the devices directly. Physical iPhone-to-Switch hosting is still pending validation."))
                        .font(.system(size: 12)).foregroundStyle(StudioStyle.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            StudioPanel {
                VStack(alignment: .leading, spacing: 14) {
                    Label(t("Create a local room"), systemImage: "person.2").font(.system(size: 17, weight: .medium))
                    instruction(1, "Start the bridge on this Mac and allow Local Network access if macOS asks.")
                    instruction(2, "On the iPhone or iPad, open the port, choose the matching LAN or LDN mode and create a room.")
                    instruction(3, "On the Switch, use the same game version and local mode, then search for rooms.")
                    Text(t("This bridge supports LAN discovery on UDP 30000 and LDN discovery on UDP 11452. LDN also requires a compatible console module. It does not enable Nextendo or Nintendo online services."))
                        .font(.system(size: 12)).foregroundStyle(StudioStyle.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }.task { await model.refreshLocalDiscoveryRelay() }
    }

    private var stateTitle: String {
        if model.isStartingLocalRelay { return "Starting bridge…" }
        if model.isStoppingLocalRelay { return "Stopping bridge…" }
        if model.localRelaySnapshot.isRunning {
            return model.localRelaySnapshot.queriesReceived == 0 ? "Bridge active · waiting for searches" : "Bridge active · discovery traffic received"
        }
        return "Bridge off"
    }

    private func instruction(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number.formatted()).font(.system(size: 12, weight: .semibold)).foregroundStyle(StudioStyle.muted).frame(width: 18)
            Text(t(text)).fixedSize(horizontal: false, vertical: true)
        }.accessibilityElement(children: .combine)
    }
}

private struct RelayTrafficView: View {
    let snapshot: LocalDiscoveryRelaySnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 26) { counters }
                VStack(alignment: .leading, spacing: 10) { counters }
            }
            if snapshot.interfaceCount > 0 {
                Text(String(format: t("Local network interfaces: %d"), snapshot.interfaceCount))
                    .font(.system(size: 12)).foregroundStyle(StudioStyle.muted)
            }
        }
    }

    @ViewBuilder private var counters: some View {
        counter("Searches received", value: snapshot.queriesReceived)
        counter("Unicast queries sent", value: snapshot.queriesForwarded)
        counter("Replies relayed", value: snapshot.responsesForwarded)
        counter("Packets discarded", value: snapshot.packetsDropped)
    }

    private func counter(_ title: String, value: UInt64) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value.formatted()).font(.system(size: 18, weight: .medium, design: .monospaced)).monospacedDigit()
            Text(t(title)).font(.system(size: 11)).foregroundStyle(StudioStyle.muted)
        }.accessibilityElement(children: .combine)
    }
}
