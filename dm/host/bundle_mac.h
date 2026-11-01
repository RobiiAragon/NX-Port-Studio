// A packed Mac app boots its host in the process LaunchServices created.
// -1 continues into the host with prepared argv; >=0 returns without a guest.
#pragma once
int dm_mac_bundle_prepare(int *argc, char ***argv);
