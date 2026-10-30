# Mario Kart 8 Deluxe 3.0.5, main fe941ed5ba14be5d505698da1bbf4fe7.
# Projection site identified by Fl4sh9174's public 3.0.5 ultrawide mod:
# https://github.com/Fl4sh9174/Switch-Emulator-Ultrawide-FPS-Mods/tree/b06fa4c49fcb6c10e5b233eaeb54753dd0f3d74d
# The native stubs below use the rewriter's own patch area and runtime state;
# they do not reuse the mod's code caves or change the game's frame interval.
from nso_asm import ADRP, B

ASPECT_BUILD = 'fe941ed5ba14be5d505698da1bbf4fe7'


def display_aspect(ctx):
    here, emit = ctx.here, ctx.emit
    # View rectangle width / height, stored as the perspective camera's aspect.
    # Keep the game's split-screen ratio and multiply by output / native aspect.
    ctx.site(0x3cb1b4, '2018201e20b100bd')
    start = here()
    for w in (0xa9be27e8,       # stp x8,x9,[sp,#-32]!
              0x3d8007e1,      # str q1,[sp,#16] (s1 is live after the hook)
              0x1e201820,      # fdiv s0,s1,s0 (original)
              0xd53b4209):     # mrs x9,nzcv (original site preserves flags)
        emit(w)
    emit(ADRP(8, here(), ctx.state))
    for w in (0xbd403901,       # ldr s1,[x8,#0x38] (zero until host startup)
              0x1e202028,       # fcmp s1,#0.0
              0x5400004d,       # b.le done (+2)
              0x1e210800,       # fmul s0,s0,s1
              0xd51b4209,       # done: msr nzcv,x9
              0x3dc007e1,       # ldr q1,[sp,#16]
              0xa8c227e8):      # ldp x8,x9,[sp],#32
        emit(w)
    emit(B(here(), 0x3cb1b8))
    ctx.put(0x3cb1b4, [B(0x3cb1b4, start)], 'camera aspect: original view ratio times output/native ratio (1 = unchanged)')

    # UI layout's identity 3x4 matrix. Call the original memcpy first and change
    # only m00; all other fields, including the vertical scale, stay intact.
    # The public adjusted-HUD patch identifies this site but replaces the copy.
    ctx.site(0x8c7034, '211c0a94')
    start = here()
    emit(0xa9be7bfd)             # stp x29,x30,[sp,#-32]!
    emit(0xf9000be0)             # str x0,[sp,#16]
    emit(B(here(), 0xb4e0b8) | 0x80000000)  # bl original memcpy
    emit(0xf9400be0)             # ldr x0,[sp,#16] (memcpy's return value)
    emit(ADRP(8, here(), ctx.state))
    for w in (0xbd403900,        # ldr s0,[x8,#0x38]
              0x1e202008,        # fcmp s0,#0.0
              0x5400008d,        # b.le done (+4)
              0xbd400001,        # ldr s1,[x0]
              0x1e201821,        # fdiv s1,s1,s0
              0xbd000001,        # str s1,[x0]
              0xa8c27bfd,        # done: ldp x29,x30,[sp],#32
              0xd65f03c0):       # ret
        emit(w)
    ctx.put(0x8c7034, [B(0x8c7034, start) | 0x80000000], 'UI matrix: copy original then compensate horizontal scale for output aspect')


# Opt-in candidate. The launcher keeps it disabled until visual qualification;
# DM_DISPLAY_WIDE=1 permits isolated developer tests of this exact rewritten build.
DISPLAY_ASPECT = {ASPECT_BUILD: display_aspect}
