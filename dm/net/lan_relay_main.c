// Diagnostic runner for the same C service embedded in NX Port Studio.
#include "lan_relay.h"
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
static volatile sig_atomic_t stopped;
static void stop_signal(int value) { (void)value;stopped=1; }
int main(int argc,char **argv) {
    unsigned seconds=180;dm_lan_relay_config config={0};
    for(int i=1;i<argc;++i) {
        if(!strcmp(argv[i],"--seconds")&&i+1<argc) {
            char *end;unsigned long value=strtoul(argv[++i],&end,10);
            if(*end||!value||value>3600) { fprintf(stderr,"--seconds must be 1..3600\n");return 2; }seconds=(unsigned)value;
        } else if(!strcmp(argv[i],"--protocol")&&i+1<argc) {
            const char *value=argv[++i];config.protocols=!strcmp(value,"pia")?1:!strcmp(value,"ldn")?2:!strcmp(value,"all")?3:0;
            if(!config.protocols) { fprintf(stderr,"--protocol must be pia, ldn or all\n");return 2; }
        } else if(!strcmp(argv[i],"--interface")&&i+1<argc)config.interface_name=argv[++i];
        else { fprintf(stderr,"Usage: nx-discovery-relay [--seconds 180] [--protocol pia|ldn|all] [--interface NAME]\n");return 2; }
    }
    dm_lan_relay *relay=NULL;dm_lan_relay_snapshot snapshot;
    dm_lan_relay_status status=dm_lan_relay_start(&config,&relay,&snapshot);
    if(status!=DM_LAN_RELAY_OK) {
        fprintf(stderr,"discovery relay start failed: status=%u system_errno=%u%s\n",status,snapshot.system_errno,
                status==DM_LAN_RELAY_PORT_BUSY?" (UDP 30000 or 11452 is occupied; close the Mac game or other relay)":"");return 1;
    }
    signal(SIGINT,stop_signal);signal(SIGTERM,stop_signal);
    for(unsigned i=0;i<seconds&&!stopped;++i) {
        dm_lan_relay_snapshot_get(relay,&snapshot);
        printf("relay running=%u interfaces=%u queries=%llu fanout=%llu replies=%llu rejected=%llu pending=%u expired=%llu limited=%llu status=%u errno=%u\n",
               snapshot.running,snapshot.interfaces,(unsigned long long)snapshot.queries,(unsigned long long)snapshot.fanout,
               (unsigned long long)snapshot.replies,(unsigned long long)snapshot.rejected,snapshot.active_queries,
               (unsigned long long)snapshot.expired,(unsigned long long)snapshot.rate_limited,snapshot.status,snapshot.system_errno);fflush(stdout);
        if(!snapshot.running)break;sleep(1);
    }
    dm_lan_relay_stop(relay);return snapshot.status==DM_LAN_RELAY_OK?0:1;
}
