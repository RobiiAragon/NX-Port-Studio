// ErrorResultVariant's pure SDK constructors/getters remain in the guest.
// I checked their tag/payload ABI in SDK 3, 4, 7, 8 and 16: u32 tag at +0,
// Result at +4 for tag 1, packed ErrorCode at +4 for tag 2. No guest address,
// account identifier or surrounding application buffer belongs in this log.
#include "hle.h"

HLE_FORCE("_ZN2nn3err9ShowErrorERKNS0_18ErrorResultVariantE", "error display applet; log only its tagged numeric Result or ErrorCode", void, h_err_ShowVar, const void *variant) {
    DM_APPLET("error");
    if (!variant) { LOG("game asks to show an error (ErrorResultVariant): null"); return; }
    const uint8_t *bytes = variant;
    uint32_t tag;
    memcpy(&tag, bytes, sizeof tag);
    if (tag == 1) {
        uint32_t result;
        memcpy(&result, bytes + 4, sizeof result);
        LOG("game asks to show an error (ErrorResultVariant): tag=1 result=0x%08x", result);
    } else if (tag == 2) {
        // The 64-bit ErrorCode payload is deliberately only four-byte aligned.
        uint64_t code;
        memcpy(&code, bytes + 4, sizeof code);
        LOG("game asks to show an error (ErrorResultVariant): tag=2 code=%04u-%04u", (unsigned)(uint32_t)code, (unsigned)(code >> 32));
    } else {
        // The default constructor initializes only its tag. Unknown variants
        // likewise provide no permission to inspect uninitialized payload.
        LOG("game asks to show an error (ErrorResultVariant): tag=%u (no decoded payload)", tag);
    }
}
