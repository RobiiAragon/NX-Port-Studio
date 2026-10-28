import SwiftUI
import PortCore

struct FirmwareView: View {
    @Bindable var model: StudioModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            StudioPanel {
                VStack(alignment: .leading, spacing: 16) {
                    Label(t("System resources from your Switch"), systemImage: "shippingbox.and.arrow.backward")
                        .font(.system(size: 17, weight: .medium))
                    Text(t("Import a firmware dump to provide Mii models and original fonts to games that request them."))
                        .foregroundStyle(StudioStyle.muted).fixedSize(horizontal: false, vertical: true)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) { importButtons }
                        VStack(alignment: .leading, spacing: 10) { importButtons }
                    }.disabled(model.isBusy || model.isPreparing || model.keysPath.isEmpty)
                    HStack(spacing: 10) {
                        Label(t(model.keysPath.isEmpty ? "prod.keys required" : "Uses the prod.keys selected for your ports"),
                              systemImage: model.keysPath.isEmpty ? "key" : "key.fill")
                            .font(.system(size: 12)).foregroundStyle(StudioStyle.muted)
                        Spacer()
                        Button(t(model.keysPath.isEmpty ? "Import keys" : "Change keys")) { model.chooseKeys() }
                            .buttonStyle(QuietButtonStyle()).disabled(model.isBusy)
                    }
                }
            }
            StudioPanel {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text(t("Firmware for new ports")).font(.system(size: 16, weight: .medium))
                        Spacer()
                        Button(t("Refresh")) { model.reloadFirmware() }.buttonStyle(QuietButtonStyle()).disabled(model.isBusy)
                    }
                    Picker(t("Firmware for new ports"), selection: $model.selectedFirmwarePath) {
                        Text(t("Use built-in fallback resources")).tag("")
                        if !model.selectedFirmwarePath.isEmpty && model.selectedFirmware == nil {
                            Text(t("Previously selected firmware is missing")).tag(model.selectedFirmwarePath)
                        }
                        ForEach(model.importedFirmware) { imported in
                            Text("\(imported.catalog.firmwareVersion) · \(imported.catalog.resources.count) " + t("resource archives"))
                                .tag(imported.directoryURL.path)
                        }
                    }.labelsHidden().disabled(model.isBusy)
                    if let selected = model.selectedFirmware {
                        HStack(spacing: 12) {
                            Label(selected.catalog.firmwareVersion, systemImage: "checkmark.seal")
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: selected.catalog.resourceBytes, countStyle: .file))
                                .foregroundStyle(StudioStyle.muted)
                        }
                        ForEach(selected.catalog.resources) { resource in
                            HStack(alignment: .top, spacing: 14) {
                                Image(systemName: resource.titleId == "0100000000000802" ? "person.crop.square" : "doc")
                                    .frame(width: 20).foregroundStyle(StudioStyle.muted)
                                Text(resourceName(resource)).fontWeight(.medium)
                                Spacer()
                                Text(ByteCountFormatter.string(fromByteCount: resource.bytes, countStyle: .file))
                                    .font(.system(size: 12)).foregroundStyle(StudioStyle.muted)
                            }
                        }
                        Text((selected.directoryURL.path as NSString).abbreviatingWithTildeInPath).font(.system(size: 11)).foregroundStyle(StudioStyle.muted)
                            .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                        Button(t("Show imported resources")) { NSWorkspace.shared.open(selected.directoryURL) }.buttonStyle(.plain)
                    } else {
                        Text(t(model.selectedFirmwarePath.isEmpty ? "No firmware resources selected. Imported dumps stay on this Mac and can be selected for later ports." : "The selected firmware import is missing. Import it again or select the built-in fallback."))
                            .font(.system(size: 12)).foregroundStyle(StudioStyle.muted).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Text(t("The importer verifies the system version and selected data archives. Ports include the supported resources; console keys and system executables are not included."))
                .font(.system(size: 12)).foregroundStyle(StudioStyle.muted).fixedSize(horizontal: false, vertical: true)
        }.task { model.reloadFirmware() }
    }
    @ViewBuilder private var importButtons: some View {
        Button(t("Import ZIP")) { model.chooseFirmwareZIP() }.buttonStyle(PrimaryButtonStyle())
        Button(t("Import folder")) { model.chooseFirmwareFolder() }.buttonStyle(QuietButtonStyle())
        Button(t("Use installed Ryujinx firmware")) { model.importRyujinxFirmware() }.buttonStyle(QuietButtonStyle())
    }
    private func resourceName(_ resource: FirmwareCatalog.Resource) -> String {
        switch resource.titleId {
        case "0100000000000800": t("System certificate store")
        case "0100000000000802": t("Mii models and textures")
        case "0100000000000809": t("Verified system version")
        case "0100000000000805": t("Input method dictionaries")
        case "0100000000000810": t("Nintendo symbols font")
        case "0100000000000811": t("Standard font")
        case "0100000000000812": t("Korean font")
        case "0100000000000813": t("Traditional Chinese font")
        case "0100000000000814": t("Simplified Chinese font")
        default: resource.name
        }
    }
}
