#pragma once
// Start an event-driven, non-GUI child only when cloud saves are enabled. It
// acknowledges that NOTE_EXIT is armed before the caller starts guest code.
int dm_mac_save_supervisor_start(const char *helper, const char *save, const char *title);
