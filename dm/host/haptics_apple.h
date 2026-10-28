// Shared Core Haptics output for the Mac and iOS front ends. Configure routes before guest boot.
#pragma once
#import <GameController/GameController.h>
#include "hle_haptics.h"
#include <stdbool.h>
void dm_haptics_apple_init(void);
void dm_haptics_apple_controller(int player, GCController *controller);
void dm_haptics_apple_controller_pair(int player, GCController *left, GCController *right);
void dm_haptics_apple_shutdown(void);
// Optional platform adapter when it provides more precise hardware output.
// Called on the rumble queue; implementations must enqueue hardware work without
// blocking that queue or synchronously calling the main thread. NULL unregisters.
void dm_haptics_apple_raw_handler(bool (*available)(GCController *),
                                void (*send)(GCController *, const dm_vibration motor[2]));
