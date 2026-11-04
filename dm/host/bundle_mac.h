// A packed Mac app boots its host in the process LaunchServices created.
// -1 continues into the host with prepared argv; >=0 returns without a guest.
#pragma once
int dm_mac_bundle_prepare(int *argc, char ***argv);
// Packed apps only: finish the async account preparation on the guest worker,
// after mode selection and before BCAT/SDK calls. Never call on the AppKit thread.
void dm_mac_bundle_prepare_account(void);
