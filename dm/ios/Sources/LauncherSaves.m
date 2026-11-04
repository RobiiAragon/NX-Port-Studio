// Export one committed filesystem version. The runtime owns the same locks as
// CommitSaveData, so an early loader or cloud sync cannot tear this snapshot.
#import <Foundation/Foundation.h>
#include "../../host/save_archive.h"
#include <errno.h>
#include <unistd.h>
int dm_fs_clone_committed(const char *directory,const char *destination);
int dm_launcher_save_export(const char *root,const char *slot,const char *zip,dm_save_archive_operation *out) {
    if(!root||!slot||!zip||!out||(strcmp(slot,"save")&&strcmp(slot,"save_device")))return EINVAL;
    memset(out,0,sizeof *out);
    @autoreleasepool {
        NSString *template=[NSTemporaryDirectory() stringByAppendingPathComponent:@"jksv-snapshot-XXXXXX"];
        char *scratch=strdup(template.fileSystemRepresentation);if(!scratch)return ENOMEM;
        if(!mkdtemp(scratch)){int error=errno;free(scratch);return error;}
        NSString *temporary=[NSString stringWithUTF8String:scratch];free(scratch);
        NSString *source=[[NSString stringWithUTF8String:root] stringByAppendingPathComponent:[NSString stringWithUTF8String:slot]];
        NSString *snapshot=[temporary stringByAppendingPathComponent:@"committed"];
        int error=0;
        if(dm_fs_clone_committed(source.fileSystemRepresentation,snapshot.fileSystemRepresentation))error=errno?:EIO;
        else { error=dm_save_zip_create(snapshot.fileSystemRepresentation,zip,NULL,0,&out->info);out->installed=!error; }
        [NSFileManager.defaultManager removeItemAtPath:temporary error:nil];
        return error;
    }
}
