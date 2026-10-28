// Real input math and preferences, without a paired controller or a game.
#import <Cocoa/Cocoa.h>
#import <GameController/GameController.h>
#define DM_GAME_ID "test-controls"
#define DM_GAME_NAME "Controls Test"
#include "../controls_mac.inc"
#include "../controller_faces.h"
@interface TestFaceButton : NSObject
@property NSString *sfSymbolsName;
@property NSString *unmappedSfSymbolsName;
@property(getter=isPressed) BOOL pressed;
@end
@implementation TestFaceButton
@end
@interface TestFaceProfile : NSObject
@property NSDictionary *buttons;
@property BOOL hasRemappedElements;
@end
@implementation TestFaceProfile
@end
@interface TestFaceController : NSObject
@property TestFaceProfile *physicalInputProfile;
@property NSString *productCategory;
@end
@implementation TestFaceController
@end
static int changes;
static void controls_apply_changed(void) { changes++; }
static int checks, fails;
#define CHECK(c, msg) do { checks++; if (!(c)) { fails++; fprintf(stderr,"FAIL: %s (line %d)\n",msg,__LINE__); } } while (0)
int main(int argc, const char **argv) { @autoreleasepool {
    if (argc > 1 && !strcmp(argv[1],"--ui")) {
        [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        dm_controls_defaults(&g_controls); g_controls_editor=[DmControlsEditor new]; [g_controls_editor showControls:nil];
        [NSApp activateIgnoringOtherApps:YES]; [NSApp run]; return 0;
    }
    CHECK(dm_controls_nintendo_profile("Nintendo Switch Joy-Con (L/R)") && dm_controls_nintendo_profile("Switch Pro Controller"),"identify actual Nintendo profiles");
    CHECK(!dm_controls_nintendo_profile("Xbox Wireless Controller") && !dm_controls_nintendo_profile(NULL),"other controllers keep their physical position layout");
    CHECK(dm_controls_face_buttons(1,1,0,0,0)==DM_BTN_A && dm_controls_face_buttons(1,0,1,0,0)==DM_BTN_B,"Nintendo printed A/B labels match guest A/B");
    CHECK(dm_controls_face_buttons(0,1,0,0,0)==DM_BTN_B && dm_controls_face_buttons(0,0,1,0,0)==DM_BTN_A,"Xbox south/east positions match Nintendo B/A");
    const char *nintendoGlyphs[] = {"a.circle", "b.circle", "x.circle", "y.circle"};
    const char *positionalNintendoGlyphs[] = {"b.circle", "a.circle", "y.circle", "x.circle"};
    const char *missingGlyphs[] = {"a.circle", NULL, "x.circle", "y.circle"};
    CHECK(dm_controls_nintendo_face_labels("Nintendo Switch Joy-Con (L/R)", nintendoGlyphs),"real Nintendo category and glyphs confirm printed labels");
    CHECK(!dm_controls_nintendo_face_labels("Nintendo Switch Joy-Con (L/R)", positionalNintendoGlyphs),"already normalized Nintendo profile is not swapped twice");
    CHECK(!dm_controls_nintendo_face_labels("Xbox Wireless Controller", nintendoGlyphs),"Xbox glyph letters retain Nintendo positional mapping");
    CHECK(!dm_controls_nintendo_face_labels("Nintendo Switch Joy-Con (L/R)", missingGlyphs),"missing glyph evidence keeps documented profile positions");
    TestFaceController *faceController = [TestFaceController new];
    faceController.productCategory = @"Nintendo Switch Joy-Con (L/R)";
    faceController.physicalInputProfile = [TestFaceProfile new];
    NSMutableDictionary *faceInputs = [NSMutableDictionary new];
    NSString *faceNames[] = {GCInputButtonA,GCInputButtonB,GCInputButtonX,GCInputButtonY};
    for (int i=0;i<4;i++) {
        TestFaceButton *button=[TestFaceButton new];
        button.unmappedSfSymbolsName=[NSString stringWithUTF8String:nintendoGlyphs[i]];
        button.sfSymbolsName=button.unmappedSfSymbolsName; faceInputs[faceNames[i]]=button;
    }
    faceController.physicalInputProfile.buttons=faceInputs;
    TestFaceButton *faceA=faceInputs[GCInputButtonA], *faceB=faceInputs[GCInputButtonB];
    faceA.pressed=YES;
    CHECK(dm_gc_face_buttons((id)faceController)==DM_BTN_A,"reported Nintendo A reaches guest A without an extra positional swap");
    faceController.physicalInputProfile.hasRemappedElements=YES;
    faceA.sfSymbolsName=@"b.circle"; faceB.sfSymbolsName=@"a.circle";
    CHECK(dm_gc_face_buttons((id)faceController)==DM_BTN_A,"system customization does not change the original profile naming convention");
    faceController.productCategory=@"Xbox Wireless Controller";
    CHECK(dm_gc_face_buttons((id)faceController)==DM_BTN_B,"the same logical input on Xbox remains the lower Nintendo B position");
    dm_controls c; dm_controls_defaults(&c);
    unsigned char held[128]={0}; uint64_t buttons; int32_t axes[4];
    held[38]=1; held[13]=1; dm_controls_keyboard(&c,held,&buttons,axes);
    CHECK(buttons==DM_BTN_A && axes[1]==DM_STICK_MAX,"default key/button and left stick mapping");
    c.keys[0]=7; c.keys[21]=9; held[7]=1; held[9]=1; dm_controls_keyboard(&c,held,&buttons,axes);
    CHECK(buttons==DM_BTN_A && axes[3]==DM_STICK_MAX,"custom key and right stick mapping");
    memset(held,0,sizeof held); dm_controls_keyboard(&c,held,&buttons,axes);
    CHECK(!buttons && !axes[0] && !axes[1] && !axes[2] && !axes[3],"focus/key release clears every mapped action");
    c.buttons[0]=1; c.buttons[1]=0; c.buttons[16]=6;
    CHECK(dm_controls_buttons(&c,DM_BTN_B)==DM_BTN_A,"controller A/B swap");
    CHECK((dm_controls_buttons(&c,DM_BTN_L)&DM_BTN_SHAKE)!=0,"controller shake binding");
    c.swap_sticks=1; c.invert_lx=1; int32_t a[]={100,200,-300,400}; dm_controls_sticks(&c,a);
    CHECK(a[0]==300 && a[1]==400 && a[2]==100 && a[3]==200,"stick swap and inversion order");
    c.combine=1; c.motion=0;
    dm_controls copy; controls_decode(&copy,controls_encode(&c));
    CHECK(!memcmp(&c,&copy,sizeof c),"preferences round trip every mapping and flag");
    [controls_preferences() setObject:controls_encode(&c) forKey:controls_preference_key()]; controls_load();
    CHECK(!memcmp(&c,&g_controls,sizeof c),"saved mapping loads from per-game user preferences");
    [controls_preferences() removeObjectForKey:controls_preference_key()];
    controls_decode(&copy,@{@"keys":@"invalid",@"motion":@"invalid",@"combine":@[]} );
    dm_controls defaults; dm_controls_defaults(&defaults);
    CHECK(!memcmp(&defaults,&copy,sizeof copy),"malformed preferences preserve defaults");
    dm_motion_state motion;
    dm_motion_convert(&motion,(double[]){0,0,-1},(double[]){0,0,6.283185307179586},(double[]){0,0,0,1});
    CHECK(motion.acc[2]==-1 && fabsf(motion.gyro[2]-1)<0.00001 && motion.dir[0]==1 && motion.dir[4]==1 && motion.dir[8]==1,"motion units and identity direction");
    double h=sqrt(0.5); dm_motion_convert(&motion,(double[]){1,2,3},(double[]){0,0,0},(double[]){0,0,h,h});
    CHECK(fabsf(motion.angle[2]-0.25f)<0.00001 && fabsf(motion.dir[1]-1)<0.00001 && fabsf(motion.dir[3]+1)<0.00001,"quaternion quarter-turn direction and angle");
    printf("Mac controls: %d checks, %d failed\n",checks,fails); return fails != 0;
} }
