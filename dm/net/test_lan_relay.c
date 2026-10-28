// Logical 127/29 adapter with a real UDP peer and original client on 127.0.0.1.
// The fixture maps only the original client's return address to assigned
// loopback, avoiding interface aliases, broadcasts, game data or external LAN.
#include "lan_relay.h"
#include "../host/hle_ldn.h"
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <net/if.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>
static unsigned checks;
#define CHECK(x) do { ++checks;if(!(x)){fprintf(stderr,"FAIL %d: %s (errno %d)\n",__LINE__,#x,errno);abort();} } while(0)
static int udp(unsigned *port) {
    int fd=socket(AF_INET,SOCK_DGRAM,0);CHECK(fd>=0);struct sockaddr_in a={.sin_len=sizeof a,.sin_family=AF_INET,.sin_addr={htonl(INADDR_LOOPBACK)}};
    CHECK(!bind(fd,(struct sockaddr *)&a,sizeof a));socklen_t n=sizeof a;CHECK(!getsockname(fd,(struct sockaddr *)&a,&n));*port=ntohs(a.sin_port);return fd;
}
static unsigned free_port(void) { unsigned port;int fd=udp(&port);close(fd);return port; }
static int receive(int fd,void *bytes,size_t size,struct sockaddr_in *from,int timeout) {
    struct pollfd p={fd,POLLIN,0};if(poll(&p,1,timeout)!=1)return -1;socklen_t n=sizeof *from;return (int)recvfrom(fd,bytes,size,0,(struct sockaddr *)from,&n);
}
static void send_packet(int fd,const void *bytes,size_t size,struct sockaddr_in to) { CHECK(sendto(fd,bytes,size,0,(struct sockaddr *)&to,sizeof to)==(ssize_t)size); }
static size_t pia(uint8_t *out,int response,unsigned counter) {
    size_t size=response?0x3f:0x12f;memset(out,0,size);out[0]=response?1:0;out[5]=1;out[14]=(uint8_t)counter;return size;
}
static dm_ldn_network network(void) {
    dm_ldn_network n={0};n.max_nodes=8;n.node_count=1;n.common.type=2;n.common.ssid.len=3;memcpy(n.common.ssid.text,"abc",4);
    n.nodes[0].connected=1;n.nodes[0].ip=INADDR_LOOPBACK;n.nodes[0].version=1;strcpy(n.nodes[0].name,"fixture host");return n;
}
static dm_lan_relay_test_interface adapter(void) { return (dm_lan_relay_test_interface){htonl(0x7f000002),htonl(0xfffffff8),if_nametoindex("lo0"),IFF_UP|IFF_BROADCAST}; }
static dm_lan_relay *start(unsigned protocol,unsigned listen,unsigned peer) {
    dm_lan_relay *r=NULL;CHECK(dm_lan_relay_test_start(protocol,(uint16_t)listen,(uint16_t)peer,adapter(),&r)==DM_LAN_RELAY_OK&&r);return r;
}
static int inject(dm_lan_relay *r,unsigned protocol,unsigned source_port,const void *bytes,size_t size) {
    return dm_lan_relay_test_query(r,protocol,htonl(0x7f000003),(uint16_t)source_port,htonl(0x7f000007),adapter().index,bytes,size);
}
static void framing(void) {
    uint8_t bytes[2049];size_t n=pia(bytes,0,1);CHECK(dm_lan_relay_packet_valid(1,0,bytes,n));CHECK(!dm_lan_relay_packet_valid(1,1,bytes,n));
    for(size_t i=0;i<n;++i)CHECK(!dm_lan_relay_packet_valid(1,0,bytes,i));
    bytes[14]=0;CHECK(!dm_lan_relay_packet_valid(1,0,bytes,n));bytes[14]=1;bytes[5]=2;CHECK(!dm_lan_relay_packet_valid(1,0,bytes,n));bytes[5]=1;bytes[6]=2;CHECK(!dm_lan_relay_packet_valid(1,0,bytes,n));
    n=pia(bytes,1,17);CHECK(dm_lan_relay_packet_valid(1,1,bytes,n));CHECK(!dm_lan_relay_packet_valid(1,1,bytes,n+1));
    memset(bytes,0,sizeof bytes);bytes[1]=0x14;bytes[2]=0x45;bytes[3]=0x11;CHECK(dm_lan_relay_packet_valid(2,0,bytes,12));
    bytes[5]=1;CHECK(!dm_lan_relay_packet_valid(2,0,bytes,12));bytes[5]=0;bytes[4]=1;CHECK(!dm_lan_relay_packet_valid(2,0,bytes,12));
    dm_ldn_network room=network();int count=dm_ldn_packet_encode(bytes,sizeof bytes,1,&room,sizeof room,1);CHECK(count>0&&dm_lan_relay_packet_valid(2,1,bytes,(size_t)count));
    bytes[10]=1;CHECK(!dm_lan_relay_packet_valid(2,1,bytes,(size_t)count));CHECK(!dm_lan_relay_packet_valid(3,0,bytes,12));CHECK(!dm_lan_relay_packet_valid(1,1,bytes,2049));
}
static void roundtrip(unsigned protocol) {
    unsigned pp,cp,ap,listen=free_port();int peer=udp(&pp),client=udp(&cp),attacker=udp(&ap);dm_lan_relay *r=start(protocol,listen,pp);
    uint8_t query[2048],reply[2048],received[2048];size_t qn,rn;
    if(protocol==1){qn=pia(query,0,3);rn=pia(reply,1,17);} // host counter deliberately differs
    else { qn=(size_t)dm_ldn_packet_encode(query,sizeof query,0,NULL,0,0);dm_ldn_network room=network();rn=(size_t)dm_ldn_packet_encode(reply,sizeof reply,1,&room,sizeof room,1); }
    CHECK(!inject(r,protocol,cp,query,qn));struct sockaddr_in from;
    CHECK(receive(peer,received,sizeof received,&from,500)==(int)qn&&!memcmp(received,query,qn));
    CHECK(ntohs(from.sin_port)!=listen&&ntohs(from.sin_port)!=pp); // per-query native ephemeral fd
    send_packet(attacker,reply,rn,from);struct sockaddr_in return_from;CHECK(receive(client,received,sizeof received,&return_from,30)<0);
    if(protocol==2) {
        dm_ldn_network wrong=network();wrong.nodes[0].ip=0x7f000006;int n=dm_ldn_packet_encode(received,sizeof received,1,&wrong,sizeof wrong,1);
        send_packet(peer,received,(size_t)n,from);CHECK(receive(client,received,sizeof received,&return_from,30)<0);
    }
    send_packet(peer,reply,rn,from);CHECK(receive(client,received,sizeof received,&return_from,500)==(int)rn&&!memcmp(received,reply,rn));
    CHECK(ntohs(return_from.sin_port)==listen);
    dm_lan_relay_snapshot s;dm_lan_relay_snapshot_get(r,&s);CHECK(s.queries==1&&s.replies==1&&s.rejected>0&&s.fanout>0&&s.active_queries==1);
    usleep(2100000);dm_lan_relay_snapshot_get(r,&s);CHECK(s.active_queries==0&&s.expired==1);
    send_packet(peer,reply,rn,from);CHECK(receive(client,received,sizeof received,&return_from,30)<0);
    dm_lan_relay_stop(r);close(peer);close(client);close(attacker);
}
static void guards(void) {
    unsigned pp,cp,listen=free_port();int peer=udp(&pp),client=udp(&cp);dm_lan_relay *r=start(1,listen,pp);uint8_t query[2048];size_t n=pia(query,0,1);
    CHECK(!dm_lan_relay_test_add_own(r,htonl(0x7f000006))); // a filtered-out own alias is still excluded
    CHECK(dm_lan_relay_test_query(r,1,htonl(0x7f000006),(uint16_t)cp,htonl(UINT32_MAX),adapter().index,query,n)<0);
    CHECK(dm_lan_relay_test_query(r,1,htonl(0x0a000001),(uint16_t)cp,htonl(UINT32_MAX),adapter().index,query,n)<0);
    CHECK(dm_lan_relay_test_query(r,1,htonl(0x7f000003),(uint16_t)cp,adapter().address,adapter().index,query,n)<0);
    CHECK(dm_lan_relay_test_query(r,1,htonl(0x7f000003),(uint16_t)cp,htonl(UINT32_MAX),0,query,n)<0);
    CHECK(dm_lan_relay_test_query(r,1,adapter().address,(uint16_t)cp,htonl(UINT32_MAX),adapter().index,query,n)<0);
    CHECK(inject(r,1,0,query,n)<0);CHECK(inject(r,2,cp,query,n)<0);
    // A real unicast datagram addressed to the listener is not a broadcast query.
    struct sockaddr_in to={.sin_len=sizeof to,.sin_family=AF_INET,.sin_port=htons((uint16_t)listen),.sin_addr={htonl(INADDR_LOOPBACK)}};
    send_packet(client,query,n,to);uint8_t bytes[2048];struct sockaddr_in from;CHECK(receive(peer,bytes,sizeof bytes,&from,100)<0);
    dm_lan_relay_snapshot s;dm_lan_relay_snapshot_get(r,&s);CHECK(!s.queries&&s.rejected>=7);
    CHECK(!inject(r,1,cp,query,n));CHECK(!inject(r,1,cp,query,n));dm_lan_relay_snapshot_get(r,&s);CHECK(s.queries==1); // duplicate does not extend deadline
    usleep(50000);dm_lan_relay_snapshot_get(r,&s);CHECK(s.fanout==3); // own alias, own adapter and original source are skipped
    dm_lan_relay *second=NULL;CHECK(dm_lan_relay_test_start(1,(uint16_t)listen,(uint16_t)pp,adapter(),&second)==DM_LAN_RELAY_PORT_BUSY&&!second);
    dm_lan_relay_stop(r);close(peer);close(client);
}
static unsigned descriptors(void) { unsigned count=0;for(int i=0;i<1024;++i)if(fcntl(i,F_GETFD)>=0)++count;return count; }
static void saturation_and_cleanup(void) {
    unsigned pp,cp;int peer=udp(&pp),client=udp(&cp);unsigned before=descriptors();uint8_t query[2048];dm_lan_relay *r=start(1,free_port(),pp);
    for(unsigned i=0;i<16;++i) {
        size_t n=pia(query,0,i+1);unsigned attempts=0;
        while(inject(r,1,cp,query,n)) { CHECK(++attempts<20);usleep(130000); }
    }
    dm_lan_relay_snapshot s;dm_lan_relay_snapshot_get(r,&s);CHECK(s.active_queries==16&&s.queries==16&&s.rate_limited>0);
    size_t n=pia(query,0,20);CHECK(inject(r,1,cp,query,n)<0);dm_lan_relay_stop(r);CHECK(descriptors()==before);
    for(unsigned i=0;i<30;++i) { r=start(i&1?1:2,free_port(),pp);dm_lan_relay_stop(r);CHECK(descriptors()==before); }
    dm_lan_relay_config config={.protocols=1,.interface_name="no-such-nx"};dm_lan_relay_snapshot failure;
    CHECK(dm_lan_relay_start(&config,&r,&failure)==DM_LAN_RELAY_NO_INTERFACE&&!r&&failure.status==DM_LAN_RELAY_NO_INTERFACE);
    CHECK(descriptors()==before);close(peer);close(client);
}
int main(void) { framing();roundtrip(1);roundtrip(2);guards();saturation_and_cleanup();printf("discovery relay: %u checks passed (UDP, protocol, expiry, bounds, port conflict, fd cleanup).\n",checks);return 0; }
