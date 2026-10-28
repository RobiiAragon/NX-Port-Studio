// Resolve GameController's face-button naming before applying user mappings.
// Standard profiles describe positions (south=A); Nintendo profiles can expose
// their printed A/B/X/Y labels instead. Require actual glyph evidence before
// treating a Nintendo category as label-based, rather than swapping it twice.
#pragma once
#include "controls_map.h"

static inline int dm_controls_nintendo_face_labels(const char *category, const char *const symbols[4]) {
    if (!dm_controls_nintendo_profile(category) || !symbols) return 0;
    const char expected[] = {'a', 'b', 'x', 'y'};
    for (int i = 0; i < 4; i++) if (!symbols[i] || symbols[i][0] != expected[i] || symbols[i][1] != '.') return 0;
    return 1;
}

#ifdef __OBJC__
#import <GameController/GameController.h>

static inline int dm_gc_uses_nintendo_face_labels(GCController *controller) {
    GCPhysicalInputProfile *profile = controller.physicalInputProfile;
    NSString *names[] = {GCInputButtonA, GCInputButtonB, GCInputButtonX, GCInputButtonY};
    NSString *glyphs[4]; const char *symbols[4];
    for (int i = 0; i < 4; i++) {
        GCControllerButtonInput *button = profile.buttons[names[i]];
        // Infer the profile's original naming convention, then leave the user's
        // actual remapped input values intact. Effective glyphs may change when
        // users remap buttons in Settings; those must not change this convention.
        glyphs[i] = button.unmappedSfSymbolsName;
        if (!glyphs[i] && !profile.hasRemappedElements) glyphs[i] = button.sfSymbolsName;
        symbols[i] = glyphs[i].UTF8String;
    }
    return dm_controls_nintendo_face_labels(controller.productCategory.UTF8String, symbols);
}

static inline uint64_t dm_gc_face_buttons(GCController *controller) {
    GCPhysicalInputProfile *profile = controller.physicalInputProfile;
    return dm_controls_face_buttons(dm_gc_uses_nintendo_face_labels(controller),
        profile.buttons[GCInputButtonA].isPressed, profile.buttons[GCInputButtonB].isPressed,
        profile.buttons[GCInputButtonX].isPressed, profile.buttons[GCInputButtonY].isPressed);
}
#endif
