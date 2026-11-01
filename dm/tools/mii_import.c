// Private structured transport for scripts/import_miis.py. All format and
// persistence validation comes from the same C backend the runtime uses.
#include "../host/mii_database.h"
#include <stdio.h>
#include <string.h>
int main(int argc, char **argv) {
    dm_mii_collection c={0}; dm_mii_import_result result={0}; int error=DM_MII_INVALID;
    if (argc==3 && !strcmp(argv[1],"inspect")) error=dm_mii_inspect_file(argv[2],&c);
    else if (argc==3 && !strcmp(argv[1],"list")) error=dm_mii_read(argv[2],&c);
    else if (argc==4 && !strcmp(argv[1],"import")) {
        error=dm_mii_import_file(argv[2],argv[3],&result);
        if (!error) error=dm_mii_read(argv[2],&c);
    }
    printf("{\"code\":%d,\"added\":%u,\"replaced\":%u,\"unchanged\":%u,\"records\":[",error,result.added,result.replaced,result.unchanged);
    if (!error) for (uint32_t i=0; i<c.count; ++i) {
        printf("%s\"",i ? "," : "");
        const unsigned char *p=(const unsigned char *)&c.entries[i];
        for (size_t j=0; j<sizeof(dm_mii_charinfo); ++j) printf("%02x",p[j]);
        putchar('"');
    }
    puts("]}"); return error ? 1 : 0;
}
