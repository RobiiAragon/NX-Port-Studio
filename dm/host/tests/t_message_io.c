// Original C ABI/transport fixture: real sockets, synthetic headers, no game data.
#define main socket_regression_main
#include "t_net.c"
#undef main
#include <limits.h>
#include <sys/select.h>
// Observe x0 exactly as an AArch64 caller does. A C cast to a mismatched function
// type would itself be undefined and could hide the former int/ssize_t bug.
extern long fixture_message_call(void *entry, int fd, const void *message, int flags);
__asm__(".text\n.p2align 2\n.globl _fixture_message_call\n_fixture_message_call:\n"
        "mov x16,x0\nmov x0,x1\nmov x1,x2\nmov w2,w3\nbr x16\n");
#define MSEND(s,m,f) fixture_message_call(hook("nnsocketSendMsg"),(s),(m),(f))
#define MRECV(s,m,f) fixture_message_call(hook("nnsocketRecvMsg"),(s),(m),(f))
static void message_pair(int type, int *guest, int *native, address *destination) {
    if (type == 2) {
        *guest = SOCKET(2,2,17); address a = addr(htonl(INADDR_LOOPBACK),0); unsigned size = sizeof a;
        CHECK(*guest >= 0 && BIND(*guest,&a,sizeof a) == 0 && NAME(*guest,&a,&size) == 0, "bind guest UDP message endpoint");
        *native = native_udp(destination); *destination = a;
    } else {
        int server = socket(AF_INET,SOCK_STREAM,0);
        struct sockaddr_in a = {.sin_len=sizeof a,.sin_family=AF_INET,.sin_addr.s_addr=htonl(INADDR_LOOPBACK)}; socklen_t size=sizeof a;
        CHECK(server >= 0 && !bind(server,(void *)&a,sizeof a) && !listen(server,1) && !getsockname(server,(void *)&a,&size), "bind TCP message peer");
        *guest=SOCKET(2,1,6); *destination=addr(a.sin_addr.s_addr,0); destination->port=a.sin_port;
        CHECK(*guest>=0 && dm_net_connect(*guest,destination,sizeof *destination)==0, "connect guest TCP message endpoint");
        *native=accept(server,NULL,NULL); CHECK(*native>=0,"accept TCP message endpoint"); close(server);
    }
}
static void message_abi(void) {
    unsetenv("DM_NETWORK");
    long result=MSEND(-1,(void *)1,0);
    if(result!=-1)fprintf(stderr,"SendMsg x0 error result: %ld (expected signed64 -1)\n",result);
    CHECK(result == -1 && dm_net_errno()==100, "SendMsg error returns full signed64 minus one before reading offline memory");
    CHECK(MRECV(-1,(void *)1,0) == -1 && dm_net_errno()==100, "RecvMsg error returns full signed64 minus one before reading offline memory");
    setenv("DM_NETWORK","lan",1);
    const char *aliases[]={"_ZN2nn6socket7SendMsgEiPK6msghdri","_ZN2nn6socket7SendMsgEiPKNS0_6MsgHdrENS0_7MsgFlagE",
        "_ZN2nn6socket7RecvMsgEiP6msghdri","_ZN2nn6socket7RecvMsgEiPNS0_6MsgHdrENS0_7MsgFlagE"};
    dm_net_msghdr empty={0};
    for(unsigned i=0;i<sizeof aliases/sizeof aliases[0];i++)
        CHECK(fixture_message_call(hook(aliases[i]),-1,&empty,0)==-1 && dm_net_errno()==9,"plain/named SDK message entries preserve signed64 errors");
}
static void message_datagram(void) {
    int guest,peer; address destination=addr(htonl(INADDR_LOOPBACK),0); message_pair(2,&guest,&peer,&destination);
    address peer_address; struct sockaddr_in native; socklen_t size=sizeof native;
    CHECK(!getsockname(peer,(void *)&native,&size),"obtain UDP peer address"); peer_address=addr(native.sin_addr.s_addr,0);peer_address.port=native.sin_port;
    dm_net_iovec vectors[]={{"ab",2},{NULL,0},{"cde",3}};
    dm_net_msghdr output={.name=&peer_address,.name_size=16,.vectors=vectors,.count=3,.flags=123};
    dm_net_msghdr before=output; dm_net_set_errno(77);
    CHECK(MSEND(guest,&output,0)==5 && dm_net_errno()==77 && !memcmp(&output,&before,sizeof before),"UDP gather is one real datagram and does not alter send header");
    char bytes[12]={0}; CHECK(recv(peer,bytes,sizeof bytes,0)==5 && !memcmp(bytes,"abcde",5),"native peer receives exact gathered bytes");
    struct sockaddr_in to={.sin_len=sizeof to,.sin_family=AF_INET,.sin_addr.s_addr=destination.ip,.sin_port=destination.port};
    CHECK(sendto(peer,"uvwxyz",6,0,(void *)&to,sizeof to)==6,"native sends one scatter datagram");
    char first[3]={0},second[5]={0};dm_net_iovec recv_vectors[]={{first,2},{NULL,0},{second,4}};address source={0};
    dm_net_msghdr input={.name=&source,.name_size=16,.vectors=recv_vectors,.count=3,.flags=-1};
    CHECK(MRECV(guest,&input,0)==6 && !memcmp(first,"uv",2) && !memcmp(second,"wxyz",4),"UDP scatter fills vectors in order");
    CHECK(input.name_size==16 && source.family==2 && source.port==peer_address.port && source.ip==peer_address.ip && input.flags==0 && !input.control_size,
          "UDP source address and value-result fields use the guest ABI");
    CHECK(input.vectors==recv_vectors && input.count==3 && recv_vectors[0].size==2 && recv_vectors[2].size==4,"receive never rewrites original vectors or pointers");
    int native_guest=dm_net_dup_native(guest),one=1;
    CHECK(native_guest>=0 && !setsockopt(native_guest,SOL_SOCKET,SO_TIMESTAMP,&one,sizeof one),"enable synthetic native timestamp ancillary data");
    CHECK(sendto(peer,"C",1,0,(void *)&to,sizeof to)==1 && MRECV(guest,&input,0)==1 && first[0]=='C' && input.flags==0x20 && !input.control_size,
          "zero ancillary capacity returns the actual payload with explicit Horizon MSG_CTRUNC");
    CHECK(sendto(peer,"Q",1,0,(void *)&to,sizeof to)==1,"queue an ancillary request admission check");
    input.control=bytes;input.control_size=sizeof bytes;
    CHECK(MRECV(guest,&input,0)==-1 && dm_net_errno()==95,"a requested ancillary buffer is rejected before consuming the packet");
    input.control_size=0;
    CHECK(MRECV(guest,&input,0)==1 && first[0]=='Q' && input.flags==0x20 && input.control==bytes,
          "the rejected ancillary request left the real datagram queued and exposes no control bytes");
    one=0;CHECK(!setsockopt(native_guest,SOL_SOCKET,SO_TIMESTAMP,&one,sizeof one),"disable synthetic ancillary data");close(native_guest);
    CHECK(sendto(peer,"123456789",9,0,(void *)&to,sizeof to)==9,"native sends a larger datagram");
    input.name_size=4;memset(&source,0xa5,sizeof source);recv_vectors[0].size=1;recv_vectors[2].size=2;
    CHECK(MRECV(guest,&input,0)==3 && input.flags==0x10 && input.name_size==16,"UDP truncation reports copied count and Horizon MSG_TRUNC");
    CHECK(((unsigned char *)&source)[4]==0xa5,"short source-address capacity preserves its guard bytes");
    input=(dm_net_msghdr){0};
    CHECK(MSEND(guest,(&(dm_net_msghdr){.name=&peer_address,.name_size=16}),0)==0 && recv(peer,bytes,sizeof bytes,0)==0,"zero-vector UDP send transmits an empty datagram");
    dm_net_iovec boundary[1024]={0};dm_net_msghdr maximum={.name=&peer_address,.name_size=16,.vectors=boundary,.count=1024};
    CHECK(MSEND(guest,&maximum,0)==0 && recv(peer,bytes,sizeof bytes,0)==0,"maximum supported vector count accepts a real empty datagram");
    CHECK(sendto(peer,NULL,0,0,(void *)&to,sizeof to)==0 && MRECV(guest,&input,0)==0 && input.flags==0,"zero-vector receive consumes an empty datagram");
    CHECK(MRECV(guest,&input,0x80)==-1 && dm_net_errno()==11,"DONTWAIT empty receive reports real EAGAIN");
    CHECK(sendto(peer,"X",1,0,(void *)&to,sizeof to)==1 && MRECV(guest,&input,0)==0 && input.flags==0x10,
          "zero-capacity receive consumes a nonempty datagram and reports truncation");
    CHECK(MRECV(guest,&input,0x80)==-1 && dm_net_errno()==11,"zero-capacity receive does not leave its packet queued");
    CLOSE(guest);close(peer);
}
struct message_writer { int peer; };
static void *message_split(void *p) {
    int fd=((struct message_writer *)p)->peer; send(fd,"ab",2,0);dm_guest_sleep_ns(20000000);send(fd,"cdef",4,0);return NULL;
}
static void message_stream(void) {
    int guest,peer;address unused;message_pair(1,&guest,&peer,&unused);
    char first[4]={0},last[4]={0};dm_net_iovec v[]={{first,3},{last,3}};dm_net_msghdr m={.vectors=v,.count=2};
    struct message_writer args={peer};pthread_t thread;CHECK(!pthread_create(&thread,NULL,message_split,&args),"start partial TCP message writer");
    CHECK(MRECV(guest,&m,0x40)==6 && !memcmp(first,"abc",3) && !memcmp(last,"def",3),"WAITALL advances across vectors and partial TCP arrivals");pthread_join(thread,NULL);
    CHECK(send(peer,"peek",4,0)==4,"queue TCP peek bytes");v[0].size=2;v[1].size=2;
    CHECK(MRECV(guest,&m,2)==4 && !memcmp(first,"pe",2) && !memcmp(last,"ek",2),"PEEK scatters without consuming TCP bytes");
    CHECK(MRECV(guest,&m,0)==4,"ordinary read consumes the same peeked bytes");
    CHECK(send(peer,"!",1,MSG_OOB)==1,"queue a real TCP urgent byte");
    // Darwin poll does not signal POLLPRI on this socket, while its public
    // select exceptfds path does. Synchronize this fixture with real readiness.
    int urgent_fd=dm_net_dup_native(guest);CHECK(urgent_fd>=0,"borrow native urgent-data endpoint");fd_set urgent;FD_ZERO(&urgent);FD_SET(urgent_fd,&urgent);struct timeval urgent_timeout={1,0};
    CHECK(select(urgent_fd+1,NULL,NULL,&urgent,&urgent_timeout)==1,"native exception readiness confirms the TCP urgent byte");close(urgent_fd);
    v[0].size=1;v[1].size=0;
    CHECK(MRECV(guest,&m,1)==1 && first[0]=='!',"OOB uses native urgent-data semantics");
    int64_t timeout[2]={0,30000};
    CHECK(SETOPT(guest,0xffff,0x1006,timeout,sizeof timeout)==0 && send(peer,"12",2,0)==2,"queue a partial WAITALL read with a real receive timeout");
    v[0].size=3;v[1].size=3;
    CHECK(MRECV(guest,&m,0x40)==2 && !memcmp(first,"12",2),"WAITALL timeout returns only the actual partial bytes");
    dm_net_iovec send_vectors[]={{"xy",2},{"z",1}};dm_net_msghdr send_header={.vectors=send_vectors,.count=2};
    CHECK(MSEND(guest,&send_header,0x20000)==3,"C MSG_NOSIGNAL supports gathered stream sends");char received[8]={0};CHECK(recv(peer,received,sizeof received,0)==3 && !memcmp(received,"xyz",3),"native stream reads the gathered bytes");
    close(peer);CHECK(MRECV(guest,&m,0)==0,"stream EOF returns zero");
    int zero=0;CHECK(SETOPT(guest,0xffff,0x800,&zero,sizeof zero)==0,"disable socket-wide suppression to check the per-call NOSIGNAL flag");
    CHECK(dm_net_shutdown(guest,1)==0 && MSEND(guest,&send_header,0x20000)==-1 && dm_net_errno()==32 && !sigpipe_count,"stream send after shutdown reports EPIPE without a host SIGPIPE");CLOSE(guest);
}
static void message_errors(void) {
    int fd=SOCKET(2,2,17);char bytes[8];dm_net_iovec v[]={{bytes,sizeof bytes}};dm_net_msghdr m={.vectors=v,.count=1};
    CHECK(MSEND(fd,NULL,0)==-1 && dm_net_errno()==14 && MRECV(fd,(void *)1,0)==-1 && dm_net_errno()==14,"invalid message pointers report EFAULT");
    dm_net_msghdr copy=m;copy.count=-1;CHECK(MSEND(fd,&copy,0)==-1 && dm_net_errno()==22,"negative vector count rejected");
    copy.count=1025;CHECK(MSEND(fd,&copy,0)==-1 && dm_net_errno()==22,"excessive vector count rejected before allocation");
    copy=m;copy.vectors=(void *)1;CHECK(MSEND(fd,&copy,0)==-1 && dm_net_errno()==14,"invalid vector array rejected without a host read fault");
    copy=m;copy.control=bytes;copy.control_size=1;CHECK(MSEND(fd,&copy,0)==-1 && dm_net_errno()==95 && MRECV(fd,&copy,0)==-1 && dm_net_errno()==95,"ancillary requests fail explicitly before transport");
    CHECK(MSEND(fd,&m,0x4000000)==-1 && dm_net_errno()==95 && MRECV(fd,&m,0x42)==-1 && dm_net_errno()==95,"unsupported zerocopy and PEEK+WAITALL flags fail explicitly");
    dm_net_iovec overflow[]={{bytes,SSIZE_MAX},{bytes,1}};copy=m;copy.vectors=overflow;copy.count=2;
    CHECK(MSEND(fd,&copy,0)==-1 && dm_net_errno()==22,"vector total cannot overflow signed64 byte count");
    overflow[0]=(dm_net_iovec){(void *)(UINTPTR_MAX-1),4};copy.count=1;
    CHECK(MSEND(fd,&copy,0)==-1 && dm_net_errno()==14,"vector address wrap is rejected");
    overflow[0]=(dm_net_iovec){NULL,1};CHECK(MSEND(fd,&copy,0)==-1 && dm_net_errno()==14,"nonempty null vector rejected");
    address invalid=addr(htonl(INADDR_LOOPBACK),0);invalid.family=28;copy=m;copy.name=&invalid;copy.name_size=16;
    CHECK(MSEND(fd,&copy,0)==-1 && dm_net_errno()==97,"unsupported destination family is not cast to native layout");
    copy.name=(void *)1;CHECK(MSEND(fd,&copy,0)==-1 && dm_net_errno()==14,"invalid destination rejected by guarded copy");
    size_t page=(size_t)getpagesize();void *memory=mmap(NULL,page,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANON,-1,0);CHECK(memory!=MAP_FAILED,"map protected message fixture");
    memcpy(memory,&m,sizeof m);CHECK(!mprotect(memory,page,PROT_READ),"protect receive header");
    CHECK(MRECV(fd,memory,0x80)==-1 && dm_net_errno()==14,"read-only receive header rejected before waiting");
    CHECK(!mprotect(memory,page,PROT_NONE),"make message inaccessible");CHECK(MSEND(fd,memory,0)==-1 && dm_net_errno()==14,"inaccessible header rejected without host signal");
    munmap(memory,page);CLOSE(fd);
}
struct message_job {
    int fd, sending; dm_net_msghdr message; dm_net_iovec vectors[2];
    char bytes[32768]; long result; int error; _Atomic int done;
};
static void *message_worker(void *input) {
    struct message_job *j=input;
    if(j->sending) {
        unsigned calls=0;
        do {j->result=MSEND(j->fd,&j->message,0);} while(j->result>=0 && ++calls<4096);
    } else j->result=MRECV(j->fd,&j->message,0);
    j->error=dm_net_errno();atomic_store(&j->done,1);return NULL;
}
static void message_waited(struct message_job *j,int before) {
    for(unsigned i=0;i<3000 && atomic_load(&waits)==before && !atomic_load(&j->done);i++)usleep(1000);
    CHECK(atomic_load(&waits)>before && !atomic_load(&j->done),"message operation enters an actual readiness wait");
}
static void message_lifetimes(void) {
    for(int sending=0;sending<2;sending++) {
        int guest,peer;address unused;message_pair(1,&guest,&peer,&unused);
        if(sending){int native=dm_net_dup_native(guest),size=4096;CHECK(native>=0 && !setsockopt(native,SOL_SOCKET,SO_SNDBUF,&size,sizeof size),"bound native send buffer for backpressure");close(native);CHECK(!setsockopt(peer,SOL_SOCKET,SO_RCVBUF,&size,sizeof size),"bound peer receive window");}
        struct message_job job={.fd=guest,.sending=sending};memset(job.bytes,0xa5,sizeof job.bytes);
        job.vectors[0]=(dm_net_iovec){job.bytes,sizeof job.bytes/2};job.vectors[1]=(dm_net_iovec){job.bytes+sizeof job.bytes/2,sizeof job.bytes/2};
        job.message=(dm_net_msghdr){.vectors=job.vectors,.count=2};
        int before=atomic_load(&waits);pthread_t t;CHECK(!pthread_create(&t,NULL,message_worker,&job),"start blocked message operation");message_waited(&job,before);
        CHECK(CLOSE(guest)==0,"close descriptor while message operation is blocked");
        int replacement=SOCKET(2,2,17);CHECK(replacement==guest,"reuse exact guest slot with a different socket");
        CHECK(!pthread_join(t,NULL) && job.result==-1 && job.error==9,"blocked message is cancelled by its original descriptor generation");
        CHECK(FCNTL(replacement,4,0x800)==0,"replacement descriptor remains independently usable");
        CLOSE(replacement);close(peer);
    }
}
static void message_snapshot(void) {
    int guest,peer;address destination=addr(htonl(INADDR_LOOPBACK),0);message_pair(2,&guest,&peer,&destination);
    struct message_job job={.fd=guest};job.vectors[0]=(dm_net_iovec){job.bytes,4};job.message=(dm_net_msghdr){.vectors=job.vectors,.count=1};
    pthread_t t;int before=atomic_load(&waits);CHECK(!pthread_create(&t,NULL,message_worker,&job),"start snapshot receiver");message_waited(&job,before);
    // The wait synchronizes after copyin. Mutating the original metadata now
    // must not redirect a pending receive or inflate its saved vector length.
    job.vectors[0]=(dm_net_iovec){(void *)1,UINT64_MAX};job.message.vectors=(void *)1;job.message.count=1025;
    struct sockaddr_in to={.sin_len=sizeof to,.sin_family=AF_INET,.sin_addr.s_addr=destination.ip,.sin_port=destination.port};
    CHECK(sendto(peer,"DATA",4,0,(void *)&to,sizeof to)==4,"send to pending snapshot");
    CHECK(!pthread_join(t,NULL) && job.result==4 && !memcmp(job.bytes,"DATA",4),"receive uses the one validated header/vector snapshot after its wait");
    CHECK(job.message.vectors==(void *)1 && job.message.count==1025,"receive publishes only result fields without restoring stale pointers/counts");
    CLOSE(guest);close(peer);
}
static void message_payloads(void) {
    int guest,peer;address destination=addr(htonl(INADDR_LOOPBACK),0);message_pair(2,&guest,&peer,&destination);
    struct sockaddr_in peer_addr;socklen_t n=sizeof peer_addr;CHECK(!getsockname(peer,(void *)&peer_addr,&n),"get protected-payload peer");address target=addr(peer_addr.sin_addr.s_addr,0);target.port=peer_addr.sin_port;
    size_t page=(size_t)getpagesize();void *memory=mmap(NULL,page,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANON,-1,0);CHECK(memory!=MAP_FAILED,"map message payload");memcpy(memory,"SAFE",4);
    dm_net_iovec vector={memory,4};dm_net_msghdr m={.name=&target,.name_size=16,.vectors=&vector,.count=1};
    CHECK(!mprotect(memory,page,PROT_READ),"make send payload read-only");
    CHECK(MSEND(guest,&m,0)==4,"send reads a protected readable payload without unprotecting it");char bytes[8];CHECK(recv(peer,bytes,sizeof bytes,0)==4 && !memcmp(bytes,"SAFE",4),"peer receives protected readable bytes");
    struct sockaddr_in to={.sin_len=sizeof to,.sin_family=AF_INET,.sin_addr.s_addr=destination.ip,.sin_port=destination.port};
    CHECK(sendto(peer,"FAIL",4,0,(void *)&to,sizeof to)==4,"queue invalid output test");m.name=NULL;m.name_size=0;
    dm_net_pollfd ready={guest,1,0};CHECK(POLL(&ready,1,1000)==1 && (ready.revents&1),"invalid-output datagram is actually readable");
    CHECK(MRECV(guest,&m,0x80)==-1 && dm_net_errno()==14,"unrelated read-only output remains EFAULT without a host crash");
    CHECK(!mprotect(memory,page,PROT_NONE),"make payload inaccessible");m.name=&target;m.name_size=16;
    CHECK(MSEND(guest,&m,0)==-1 && dm_net_errno()==14,"inaccessible send payload is rejected by the kernel");
    munmap(memory,page);CLOSE(guest);close(peer);
}
int main(void) {
    struct sigaction sa={.sa_handler=sigpipe};sigemptyset(&sa.sa_mask);CHECK(!sigaction(SIGPIPE,&sa,NULL),"install SIGPIPE observer for message tests");
    message_abi();message_datagram();message_stream();message_errors();message_lifetimes();message_snapshot();message_payloads();
    CHECK(atomic_load(&wait_balance)==0 && atomic_load(&contexts_entered)==atomic_load(&contexts_left) && !atomic_load(&invalid_contexts),"message HLE waits publish balanced guest contexts");
    printf("message I/O: %d checks, %d failures\n",checks,failures);return failures?1:0;
}
