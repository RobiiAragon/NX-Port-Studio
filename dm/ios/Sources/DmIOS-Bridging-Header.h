// The Objective-C functions Launcher.swift calls (CloudSaves.h). project.yml points SWIFT_OBJC_BRIDGING_HEADER here.
#import "CloudSaves.h"

#include "../../host/save_archive.h"
int dm_launcher_save_export(const char *root,const char *slot,const char *zip,dm_save_archive_operation *out);
