import SwiftUI
import PortCore

struct PersonalMiisView: View {
    @Bindable var model: StudioModel

    var body: some View {
        StudioPanel {
            VStack(alignment: .leading, spacing: 14) {
                Label(t("Your personal Miis"), systemImage: "person.crop.square")
                    .font(.system(size: 17, weight: .medium))
                Text(t("Firmware includes the models used to draw Miis. Import your own Mii exports separately to make your characters available to compatible games."))
                    .foregroundStyle(StudioStyle.muted).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button(t("Import Miis")) { model.choosePersonalMiis() }
                        .buttonStyle(PrimaryButtonStyle())
                    Button(t("Refresh")) { Task { await model.reloadMiis() } }
                        .buttonStyle(QuietButtonStyle())
                    if model.isLoadingMiis { ProgressView().controlSize(.small) }
                }.disabled(model.isBusy || model.isPreparing || model.isLoadingMiis)
                if let error = model.miiLibraryError {
                    Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                } else if model.personalMiis.count == 0 {
                    Text(t("No personal Miis imported. Games keep their built-in defaults."))
                        .foregroundStyle(StudioStyle.muted)
                } else {
                    Label(String(format: t("%d personal Miis available"), model.personalMiis.count), systemImage: "checkmark.seal")
                    ForEach(model.personalMiis.entries) { entry in
                        Text(entry.name).lineLimit(1).textSelection(.enabled)
                    }
                }
                Text(t("Accepted: .charinfo, StoreData and decrypted NFDB exports from your console. Miis stay on this Mac and are included privately in new ports. Importing Miis does not add a Mii editor."))
                    .font(.system(size: 12)).foregroundStyle(StudioStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.task { await model.reloadMiis() }
    }
}
