// Configuration, change detection and bounded numeric-only output.
#include "../nvn/nvn_resource_trace.h"
#include <stdlib.h>
#include <stddef.h>
static unsigned checks, failed;
#define CHECK(c) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #c); } } while (0)
int main(void) {
    nvn_resource_trace t; uint64_t key = 0;
    unsigned types = 0;
    CHECK(nvn_resource_trace_types(NULL,&types)); CHECK(types==0x3ff);
    CHECK(nvn_resource_trace_types("",&types)); CHECK(types==0x3ff);
    CHECK(nvn_resource_trace_types("7",&types)); CHECK(types==(1u<<7));
    CHECK(nvn_resource_trace_type_watches(types,7)); CHECK(!nvn_resource_trace_type_watches(types,2));
    CHECK(!nvn_resource_trace_type_watches(types,10)); CHECK(!nvn_resource_trace_type_watches(types,UINT32_MAX));
    CHECK(nvn_resource_trace_types("0,1,2,3,4,5,6,7,8,9",&types)); CHECK(types==0x3ff);
    CHECK(nvn_resource_trace_types("7,2,7",&types)); CHECK(types==((1u<<7)|(1u<<2)));
    const char *bad_types[]={"-1","10","07","7,","7,,2",",7"," 7","7, 2","7,2suffix","7,7,7,7,7,7,7,7,7,7,7"};
    for (unsigned i=0;i<sizeof bad_types/sizeof *bad_types;i++) { CHECK(!nvn_resource_trace_types(bad_types[i],&types)); CHECK(types==0); }
    CHECK(nvn_resource_trace_config(&t, NULL)); CHECK(!nvn_resource_trace_live(&t));
    CHECK(nvn_resource_trace_config(&t, "")); CHECK(!nvn_resource_trace_live(&t));
    const char *bad[] = {"0123456789abcde", "0123456789abcdeg", "0123456789abcdef_b", "0123456789abcdef,", ",0123456789abcdef", "0123456789abcdef, 0123456789abcdef", "0123456789abcdef,../../file"};
    for (unsigned i = 0; i < sizeof bad / sizeof *bad; i++) { CHECK(!nvn_resource_trace_config(&t, bad[i])); CHECK(!nvn_resource_trace_live(&t)); }
    char list[17 * 17 + 1] = {0};
    for (unsigned i = 0; i < 17; i++) { char k[18]; snprintf(k, sizeof k, "%s%016x", i ? "," : "", i); strcat(list, k); }
    CHECK(!nvn_resource_trace_config(&t, list)); CHECK(!nvn_resource_trace_live(&t));
    list[16 * 17 - 1] = 0; CHECK(nvn_resource_trace_config(&t, list)); CHECK(t.nkeys == 16);
    CHECK(nvn_resource_trace_config(&t, "0123456789abcdef,0123456789ABCDEF")); CHECK(t.nkeys == 1);
    CHECK(nvn_resource_trace_watches(&t, "0123456789abcdef_b", &key)); CHECK(key == 0x0123456789abcdefull);
    CHECK(!nvn_resource_trace_watches(&t, "0123456789abcdef_b.extra", &key)); CHECK(!nvn_resource_trace_watches(&t, "0000000000000000", &key));
    nvn_resource_fact a = {.key=key, .serial=7, .stage=1, .role=NVN_TRACE_COLOR, .slot=0, .descriptor=-1,
        .type=7, .format=92, .width=8, .height=8, .depth=8, .levels=1, .layers=1, .samples=1, .plane=3};
    CHECK(nvn_resource_trace_note(&t, &a)); CHECK(!nvn_resource_trace_note(&t, &a)); CHECK(t.emitted == 1);
    nvn_resource_fact b = a; b.plane = 4; CHECK(nvn_resource_trace_note(&t, &b)); CHECK(nvn_resource_trace_note(&t, &a)); CHECK(t.emitted == 3);
    // Every identity / metadata field changes the signature. Frame/pass are not
    // stored in the fact and therefore cannot consume the emission budget.
    const size_t fields[] = {offsetof(nvn_resource_fact,serial), offsetof(nvn_resource_fact,descriptor), offsetof(nvn_resource_fact,type), offsetof(nvn_resource_fact,format),
        offsetof(nvn_resource_fact,width), offsetof(nvn_resource_fact,height), offsetof(nvn_resource_fact,depth), offsetof(nvn_resource_fact,levels), offsetof(nvn_resource_fact,layers),
        offsetof(nvn_resource_fact,samples), offsetof(nvn_resource_fact,level), offsetof(nvn_resource_fact,slice), offsetof(nvn_resource_fact,plane), offsetof(nvn_resource_fact,render_layers), offsetof(nvn_resource_fact,dummy)};
    for (unsigned i = 0; i < sizeof fields / sizeof *fields; i++) { b = a; ((unsigned char *)&b)[fields[i]] ^= 1; CHECK(!nvn_resource_fact_same(&a, &b)); }
    FILE *out = tmpfile(); CHECK(out != NULL); if (!out) return 1;
    nvn_resource_trace_print(out, &a, 1, 2); nvn_resource_trace_print(out, &a, 99, 100);
    CHECK(!nvn_resource_trace_note(&t, &a)); CHECK(t.emitted == 3);
    CHECK(fseek(out,0,SEEK_SET)==0); char line[1024]; CHECK(fgets(line, sizeof line, out) != NULL);
    CHECK(strstr(line, "key=0123456789abcdef frame=1 pass=2 stage=1 role=color slot=0 serial=7 descriptor=-1 type=7 format=92 width=8 height=8 depth=8") != NULL);
    CHECK(strstr(line, "plane=3") != NULL); CHECK(strstr(line, "0x") == NULL); CHECK(strstr(line, "addr") == NULL); CHECK(strstr(line, "uniform") == NULL); CHECK(strstr(line, "pixel") == NULL); CHECK(strstr(line, "hash") == NULL);
    fclose(out);
    for (unsigned i = 0; i < 100; i++) { b = a; b.serial = 100 + i; (void)nvn_resource_trace_note(&t, &b); }
    CHECK(t.emitted == 32); CHECK(!nvn_resource_trace_live(&t)); CHECK(!nvn_resource_trace_watches(&t, "0123456789abcdef", &key)); CHECK(t.nlast == 1);
    CHECK(nvn_resource_trace_config(&t, NULL)); CHECK(!nvn_resource_trace_note(&t, &a)); CHECK(t.emitted == 0);
    printf("RESOURCE_TRACE %u checks, %u failed\n", checks, failed); return failed != 0;
}
