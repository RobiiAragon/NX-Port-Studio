# Mario Kart 8 Deluxe 3.0.5, main fe941ed5ba14be5d505698da1bbf4fe7.
# Projection site identified by Fl4sh9174's public 3.0.5 ultrawide mod:
# https://github.com/Fl4sh9174/Switch-Emulator-Ultrawide-FPS-Mods/tree/b06fa4c49fcb6c10e5b233eaeb54753dd0f3d74d
# The native stubs below use the rewriter's own patch area and runtime state;
# they do not reuse the mod's code caves or change the game's frame interval.
from nso_asm import ADRP, ADDI, LDRX, CMPR, B, STP_PRE, LDP_POST

ASPECT_BUILD = 'fe941ed5ba14be5d505698da1bbf4fe7'


def race_factor(ctx, scalar):
    """Latch one factor for camera, UI and the present ticket of this frame.

    Scene-chain clue: HarderAI-Enhanced c10f7e2, time_trial_driving_scope_v305.h.
    Independently checked against this build's current-scene getter (0x7f41b4)
    and scene vtable. RaceScene also backs the title demo, so require the local
    Grand Prix configuration (three mode words at +0/+4/+8 are all zero).
    Other race modes remain native until separately qualified. The host changes
    the requested ratio and clears the latch only at QueuePresentTexture, after
    snapshotting the preceding frame. x8/x9/flags scratch.
    """
    start, words, branches = ctx.here(), [], []
    def put(w): words.append(w)
    def pc(): return start + len(words) * 4
    def branch(word, target='commit'): branches.append((len(words), word, target)); put(0)
    put(ADRP(8, pc(), ctx.state)); put(0xbd404100 | scalar)  # frame latch at +0x40
    put(0x1e202008 | scalar << 5)
    branch(0x5400000c, 'end')    # another camera / UI draw already chose this frame's aspect
    put(0x1e2e1000 | scalar)      # fmov sN,#1.0
    put(ADRP(8, pc(), 0x12f6388)); put(LDRX(8, 8, 0x388 // 8))
    branch(0xb4000008)           # cbz x8,done (singleton storage)
    put(LDRX(8, 8)); branch(0xb4000008)
    put(LDRX(8, 8, 0x20 // 8)); branch(0xb4000008)  # scene link
    put(LDRX(8, 8, 1)); branch(0xb4000008)          # current scene
    put(LDRX(9, 8))
    put(ADRP(8, pc(), 0x125e158)); put(ADDI(8, 8, 0x158))
    put(CMPR(9, 8)); branch(0x54000001)            # b.ne done (not RaceScene)
    put(ADRP(8, pc(), 0x12f6388)); put(LDRX(8, 8, 0x388 // 8))
    branch(0xb4000008)
    put(LDRX(8, 8)); branch(0xb4000008)
    put(LDRX(8, 8, 0x20 // 8)); branch(0xb4000008)
    put(LDRX(8, 8, 1)); branch(0xb4000008)
    put(LDRX(9, 8, 0x1b0 // 8)); branch(0xb4000009)  # RaceSystem
    put(LDRX(8, 9, 0x238 // 8)); branch(0xb4000008)   # race / driver group
    put(LDRX(8, 8, 0xb0 // 8)); branch(0xb4000008)
    put(0xb9408108); put(0x7100051f); branch(0x54000001)  # group local-list length +0x80 == 1
    put(LDRX(8, 9, 0x218 // 8)); branch(0xb4000008)   # race clocks
    put(LDRX(8, 8, 0x50 // 8)); branch(0xb4000008)
    put(0xb9403909); put(0x7100193f); branch(0x54000001)  # clock state +0x38 == 6: driving, not intro / fade
    put(ADRP(8, pc(), 0x12f6388)); put(LDRX(8, 8, 0x388 // 8))
    branch(0xb4000008)
    put(LDRX(8, 8)); branch(0xb4000008)
    put(LDRX(8, 8, 0x28 // 8)); branch(0xb4000008)  # services
    put(LDRX(8, 8, 0x240 // 8)); branch(0xb4000008) # RaceConfig holder
    put(LDRX(8, 8, 0x10 // 8)); branch(0xb4000008)  # current config
    for offset in (0, 4, 8):
        put(0xb9400109 | (offset // 4) << 10)     # ldr w9,[x8,#offset]
        branch(0x35000009)                       # cbnz w9,done (not local GP)
    put(ADRP(8, pc(), ctx.state)); put(0xbd403900 | scalar)  # ldr sN,[x8,#0x38]
    put(0x1e202008 | scalar << 5)                   # fcmp sN,#0.0
    branch(0x5400000c)                             # b.gt done
    put(0x1e2e1000 | scalar)                        # zero/uninitialized state: unchanged
    commit = len(words)
    put(ADRP(8, pc(), ctx.state)); put(0xbd004100 | scalar)
    targets = {'commit': commit, 'end': len(words)}
    for i, op, target in branches:
        words[i] = op | ((targets[target] - i) << 5)
    for word in words: ctx.emit(word)


def display_aspect(ctx):
    here, emit = ctx.here, ctx.emit
    # View rectangle width / height, stored as the perspective camera's aspect.
    # Keep the game's split-screen ratio and multiply by output / native aspect.
    ctx.site(0x3cb1b4, '2018201e20b100bd')
    # Validate the field-chain getter as well as the code we replace.
    ctx.site(0x7f41b4, '085800d008c541f9080140f9081140f9000540f9c0035fd6')
    ctx.site(0x7f41cc, '085800d008c541f9080140f9081540f9002141f9c0035fd6')
    ctx.site(0x125e158, '70197f0000000000d4413d0000000000f8413d0000000000')
    ctx.display_aspect_version = 4
    start = here()
    for w in (0xa9bd27e8,       # stp x8,x9,[sp,#-48]!
              0x3d8007e1,      # str q1,[sp,#16] (s1 is live after the hook)
              0x1e201820,      # fdiv s0,s1,s0 (original)
              0xd53b4209,      # mrs x9,nzcv (original site preserves flags)
              0xf90013e9):     # str x9,[sp,#32]
        emit(w)
    race_factor(ctx, 1)
    for w in (0x1e210800,       # fmul s0,s0,s1
              0xf94013e9,       # ldr x9,[sp,#32]
              0xd51b4209,       # done: msr nzcv,x9
              0x3dc007e1,       # ldr q1,[sp,#16]
              0xa8c327e8):      # ldp x8,x9,[sp],#48
        emit(w)
    emit(B(here(), 0x3cb1b8))
    ctx.put(0x3cb1b4, [B(0x3cb1b4, start)], 'camera aspect: original view ratio times output/native ratio (1 = unchanged)')

    # Images and font glyphs use different projection-upload paths. The common
    # point is CalculateMtx: it derives their pane matrices from DrawInfo's view.
    # Keep its projection and the cached DrawInfo ORIGINAL. Pass a stack copy
    # with only its clip-X view row compensated, alive through the recursive call.
    # Recalculate panes even if the game considers their old matrices clean.
    ctx.site(0x5a0120, '285c40f908e1019129400191082400a9285840f9080800f9')
    for entry in (0x59e198, 0x73f3bc):
        ctx.site(entry, 'ff8301d1f51b00f9f44f04a9fd7b05a9')
        start = here()
        emit(B(here(), start + 12))
        original = here()
        emit(0xd10183ff)        # original sub sp,sp,#0x60; enter the unmodified function body
        emit(B(here(), entry + 4))
        emit(0xb4000001 | (((original - here()) // 4) & 0x7ffff) << 5)  # null DrawInfo: original path
        emit(LDRX(8, 0, 0x18 // 8))  # original function skips layouts without a root pane
        emit(0xb4000008 | (((original - here()) // 4) & 0x7ffff) << 5)
        emit(STP_PRE(29, 30, 31, -0x120))
        emit(ADDI(8, 31, 0x20))
        for offset in range(0, 0xe0, 0x20):
            emit(0xad400420 | (offset // 16) << 15)  # ldp q0,q1,[x1,#offset]
            emit(0xad000500 | (offset // 16) << 15)  # stp q0,q1,[x8,#offset]
        emit(0x3dc03820); emit(0x3d803900)  # copy +0xe0..ef
        emit(LDRX(9, 1, 0xf0 // 8)); emit(0xf9007909)  # copy +0xf0..f7
        emit(0xf9007d1f)        # zero trailing padding; never read beyond DrawInfo's used fields
        race_factor(ctx, 0)
        emit(ADDI(8, 31, 0x20))
        for offset in range(0x50, 0x60, 4):  # include the original row's center / translation
            emit(0xbd400101 | (offset // 4) << 10)  # ldr s1,[x8,#offset]
            emit(0x1e201821)                        # fdiv s1,s1,s0
            emit(0xbd000101 | (offset // 4) << 10)  # str s1,[x8,#offset]
        emit(0xaa0803e1)        # mov x1,x8 (temporary DrawInfo)
        emit(0x32000042)        # orr w2,w2,#1 (force all pane matrices to reflect the new ratio)
        emit(B(here(), original) | 0x80000000)
        emit(LDP_POST(29, 30, 31, 0x120)); emit(0xd65f03c0)
        ctx.put(entry, [B(entry, start)], 'UI layout: derive image/text pane matrices from a temporary original DrawInfo view')


# Opt-in candidate. The launcher keeps it disabled until visual qualification;
# DM_DISPLAY_WIDE=1 permits isolated developer tests of this exact rewritten build.
DISPLAY_ASPECT = {ASPECT_BUILD: display_aspect}
