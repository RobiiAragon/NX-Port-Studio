// Local account identity shared by services. This does not grant an online ID.
#pragma once
int dm_account_uid_exists(const void *uid);
int dm_account_copy_uid(void *output);
