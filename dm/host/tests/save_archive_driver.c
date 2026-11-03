// Source-only driver for independent Python-generated ZIP interoperability tests.
#include "../save_archive.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>

int main(int argc,char **argv) {
    dm_save_archive_info info={0};int error;
    if(argc==4&&!strcmp(argv[1],"replace")) {
        int installed=0,previous=0;error=dm_save_archive_replace(argv[2],argv[3],&installed,&previous);
        info.files=(uint64_t)installed;info.directories=(uint64_t)previous;
    }
    else if(argc==3&&!strcmp(argv[1],"lease")) {
        int shared=dm_save_archive_lock(argv[2],0);if(shared<0)return 3;
        int exclusive=dm_save_archive_lock(argv[2],1);
        error=exclusive<0&&(-exclusive==EWOULDBLOCK||-exclusive==EAGAIN)?0:EINVAL;
        if(exclusive>=0)close(exclusive);close(shared);
        exclusive=dm_save_archive_lock(argv[2],1);if(exclusive<0)error=-exclusive;else close(exclusive);
    }
    else if(argc==7&&(!strcmp(argv[1],"import")||!strcmp(argv[1],"queue"))) {
        dm_save_archive_operation op={0};
        error=(!strcmp(argv[1],"queue")?dm_save_archive_queue:dm_save_archive_import)(argv[2],argv[3],argv[4],strtoull(argv[5],NULL,16),atoi(argv[6]),&op);
        info=op.info;
    }
    else if(argc==4&&!strcmp(argv[1],"apply")) {
        dm_save_archive_operation op={0};error=dm_save_archive_apply_pending(argv[2],strtoull(argv[3],NULL,16),&op);info=op.info;
    }
    else if(argc==3&&!strcmp(argv[1],"cancel"))error=dm_save_archive_cancel_pending(argv[2]);
    else if(argc==5&&!strcmp(argv[1],"export")) {
        dm_save_archive_operation op={0};error=dm_save_archive_export(argv[2],argv[3],argv[4],&op);info=op.info;
    }
    else if(argc==6&&!strcmp(argv[1],"extract"))
        error=dm_save_zip_extract(argv[2],argv[3],strtoull(argv[4],NULL,16),atoi(argv[5]),&info);
    else if((argc==4||argc==5)&&!strcmp(argv[1],"create")) {
        unsigned char metadata[DM_SAVE_META_BYTES];size_t n=0;
        if(argc==5){FILE *f=fopen(argv[4],"rb");if(!f)return 3;n=fread(metadata,1,sizeof metadata,f);if(fgetc(f)!=EOF)n=0;fclose(f);if(n!=sizeof metadata)return 3;}
        error=dm_save_zip_create(argv[2],argv[3],n?metadata:NULL,n,&info);
    } else return 2;
    printf("%d %llu %llu %llu %d %llx %d\n",error,(unsigned long long)info.files,
        (unsigned long long)info.directories,(unsigned long long)info.bytes,
        info.has_metadata,(unsigned long long)info.title_id,info.save_type);
    return error?1:0;
}
