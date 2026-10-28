// Native Mac controls editor. Included by front_mac.m; no game code or keys enter preferences.
#include "controls_map.h"
static dm_controls g_controls;
static NSString *(^g_controls_motion_status)(GCController *);
static void controls_apply_changed(void);   // front_mac releases old input and re-reads controllers
static NSString *controls_preference_key(void) { return @"Controls.v1." DM_GAME_ID; }
static NSUserDefaults *controls_preferences(void) { return [[NSUserDefaults alloc] initWithSuiteName:@"org.nxnative.controls"]; }
static NSDictionary *controls_encode(const dm_controls *c) {
    NSMutableArray *keys = [NSMutableArray new], *buttons = [NSMutableArray new];
    for (int i = 0; i < DM_CONTROL_COUNT; i++) [keys addObject:@(c->keys[i])];
    for (int i = 0; i < 17; i++) [buttons addObject:@(c->buttons[i])];
    return @{@"keys":keys, @"buttons":buttons, @"swap":@(c->swap_sticks), @"lx":@(c->invert_lx), @"ly":@(c->invert_ly),
             @"rx":@(c->invert_rx), @"ry":@(c->invert_ry), @"motion":@(c->motion), @"combine":@(c->combine)};
}
static void controls_decode(dm_controls *c, NSDictionary *saved) {
    dm_controls_defaults(c);
    if (![saved isKindOfClass:NSDictionary.class]) return;
    NSArray *keys = saved[@"keys"], *buttons = saved[@"buttons"];
    if ([keys isKindOfClass:NSArray.class] && keys.count == DM_CONTROL_COUNT)
        for (int i = 0; i < DM_CONTROL_COUNT; i++) if ([keys[i] isKindOfClass:NSNumber.class] && [keys[i] intValue] >= -1 && [keys[i] intValue] < 128) c->keys[i] = [keys[i] intValue];
    if ([buttons isKindOfClass:NSArray.class] && buttons.count == 17)
        for (int i = 0; i < 17; i++) if ([buttons[i] isKindOfClass:NSNumber.class] && [buttons[i] intValue] >= -1 && [buttons[i] intValue] < 20) c->buttons[i] = [buttons[i] intValue];
    #define FLAG(field, key) if ([saved[key] isKindOfClass:NSNumber.class]) c->field = [saved[key] boolValue]
    FLAG(swap_sticks,@"swap"); FLAG(invert_lx,@"lx"); FLAG(invert_ly,@"ly"); FLAG(invert_rx,@"rx"); FLAG(invert_ry,@"ry"); FLAG(motion,@"motion"); FLAG(combine,@"combine");
    #undef FLAG
}
static void controls_load(void) { controls_decode(&g_controls, [controls_preferences() dictionaryForKey:controls_preference_key()]); }
static NSString *controls_key_name(int key) {
    if (key < 0) return @"Unbound";
    static NSDictionary *names;
    if (!names) names = @{@0:@"A",@1:@"S",@2:@"D",@3:@"F",@4:@"H",@5:@"G",@6:@"Z",@7:@"X",@8:@"C",@9:@"V",@11:@"B",@12:@"Q",@13:@"W",@14:@"E",@15:@"R",@16:@"Y",@17:@"T",@18:@"1",@19:@"2",@20:@"3",@21:@"4",@22:@"6",@23:@"5",@24:@"=",@25:@"9",@26:@"7",@27:@"-",@28:@"8",@29:@"0",@30:@"]",@31:@"O",@32:@"U",@33:@"[",@34:@"I",@35:@"P",@36:@"Return",@37:@"L",@38:@"J",@39:@"'",@40:@"K",@41:@";",@42:@"\\",@43:@",",@44:@"/",@45:@"N",@46:@"M",@47:@".",@48:@"Tab",@49:@"Space",@50:@"`",@51:@"Delete",@53:@"Escape",@76:@"Keypad Enter",@96:@"F5",@97:@"F6",@98:@"F7",@99:@"F3",@100:@"F8",@101:@"F9",@103:@"F11",@109:@"F10",@111:@"F12",@115:@"Home",@116:@"Page Up",@117:@"Forward Delete",@118:@"F4",@119:@"End",@120:@"F2",@121:@"Page Down",@122:@"F1",@123:@"Left Arrow",@124:@"Right Arrow",@125:@"Down Arrow",@126:@"Up Arrow"};
    return names[@(key)] ?: [NSString stringWithFormat:@"Key %d", key];
}
static NSArray<NSString *> *controls_action_names(void) {
    return @[@"A",@"B",@"X",@"Y",@"Left stick press",@"Right stick press",@"L",@"R",@"ZL",@"ZR",@"+",@"−",@"D-pad left",@"D-pad up",@"D-pad right",@"D-pad down",@"Left stick left",@"Left stick up",@"Left stick right",@"Left stick down",@"Right stick left",@"Right stick up",@"Right stick right",@"Right stick down",@"Shake"];
}
static NSArray<NSString *> *controls_source_names(void) {
    return @[@"Unbound",@"A · right",@"B · bottom",@"X · top",@"Y · left",@"Left stick press",@"Right stick press",@"L",@"R",@"ZL",@"ZR",@"Menu / +",@"Options / −",@"D-pad left",@"D-pad up",@"D-pad right",@"D-pad down",@"SL",@"SR",@"Home",@"Capture"];
}
@interface DmControlsEditor : NSWindowController <NSWindowDelegate> {
    dm_controls _draft;
    NSMutableArray<NSButton *> *_keys;
    NSMutableArray<NSPopUpButton *> *_buttons;
    NSMutableArray<NSButton *> *_flags;
    NSTextField *_status;
    NSInteger _capturing;
    id _monitor;
    NSTimer *_timer;
}
- (void)showControls:(id)sender;
@end
@implementation DmControlsEditor
- (void)stopCapture {
    if (_monitor) { [NSEvent removeMonitor:_monitor]; _monitor = nil; }
    if (_capturing >= 0 && _capturing < _keys.count) _keys[_capturing].title = controls_key_name(_draft.keys[_capturing]);
    _capturing = -1;
}
- (void)capture:(NSButton *)sender {
    [self stopCapture]; _capturing = sender.tag; sender.title = @"Press a key…";
    __weak DmControlsEditor *weakSelf = self;
    _monitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event) {
        DmControlsEditor *self = weakSelf;
        if (!self || event.window != self.window || self->_capturing < 0) return event;
        if (event.modifierFlags & NSEventModifierFlagCommand) return event;
        if (event.keyCode != 53) {
            int key = event.keyCode == 51 ? -1 : event.keyCode;
            // A key belongs to one action: moving a binding releases its previous action.
            for (int i = 0; i < DM_CONTROL_COUNT; i++) if (key >= 0 && self->_draft.keys[i] == key) self->_draft.keys[i] = -1;
            self->_draft.keys[self->_capturing] = key;
        }
        [self stopCapture]; [self reload]; return nil;
    }];
}
- (void)buttonChanged:(NSPopUpButton *)sender { _draft.buttons[sender.tag] = (int)sender.indexOfSelectedItem - 1; }
- (void)flagChanged:(NSButton *)sender {
    int *values[] = {&_draft.swap_sticks,&_draft.invert_lx,&_draft.invert_ly,&_draft.invert_rx,&_draft.invert_ry,&_draft.motion,&_draft.combine};
    *values[sender.tag] = sender.state == NSControlStateValueOn;
}
- (void)reload {
    for (int i = 0; i < DM_CONTROL_COUNT; i++) _keys[i].title = controls_key_name(_draft.keys[i]);
    for (int i = 0; i < 17; i++) [_buttons[i] selectItemAtIndex:_draft.buttons[i] + 1];
    const int values[] = {_draft.swap_sticks,_draft.invert_lx,_draft.invert_ly,_draft.invert_rx,_draft.invert_ry,_draft.motion,_draft.combine};
    for (int i = 0; i < 7; i++) _flags[i].state = values[i] ? NSControlStateValueOn : NSControlStateValueOff;
    [self updateStatus];
}
- (void)updateStatus {
    NSMutableArray *lines = [NSMutableArray new];
    for (GCController *c in GCController.controllers) {
        NSString *motion = !c.motion ? @"no motion data" : c.motion.hasRotationRate ? @"gyroscope + acceleration" : @"acceleration only";
        if (g_controls_motion_status) motion=g_controls_motion_status(c) ?: motion;
        [lines addObject:[NSString stringWithFormat:@"%@ — %@", c.vendorName ?: @"Controller", motion]];
    }
    _status.stringValue = lines.count ? [lines componentsJoinedByString:@"\n"] : @"No controller connected. Pair your Joy-Con in System Settings → Bluetooth.";
}
- (void)reset:(id)sender { (void)sender; [self stopCapture]; dm_controls_defaults(&_draft); [self reload]; }
- (void)save:(id)sender {
    (void)sender; [self stopCapture];
    for (int i = 0; i < 17; i++) _draft.buttons[i] = (int)_buttons[i].indexOfSelectedItem - 1;
    int *values[] = {&_draft.swap_sticks,&_draft.invert_lx,&_draft.invert_ly,&_draft.invert_rx,&_draft.invert_ry,&_draft.motion,&_draft.combine};
    for (int i = 0; i < 7; i++) *values[i] = _flags[i].state == NSControlStateValueOn;
    g_controls = _draft;
    [controls_preferences() setObject:controls_encode(&g_controls) forKey:controls_preference_key()];
    controls_apply_changed(); [self close];
}
- (void)cancel:(id)sender { (void)sender; [self close]; }
- (void)windowWillClose:(NSNotification *)notification { (void)notification; [self stopCapture]; [_timer invalidate]; _timer = nil; }
- (void)showControls:(id)sender {
    (void)sender; [self stopCapture]; _draft = g_controls;
    if (!self.window) {
        self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,700,680) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
        self.window.title = @"Controls — " DM_GAME_NAME; self.window.delegate = self; self.window.releasedWhenClosed = NO;
        NSView *content = self.window.contentView;
        NSTextField *hint = [NSTextField wrappingLabelWithString:@"Click a key to change it. Escape cancels; Delete clears. Controller button names follow Nintendo positions. Saved for this game on this Mac."];
        hint.frame = NSMakeRect(20,622,660,40); [content addSubview:hint];
        for (int i = 0; i < 3; i++) {
            NSTextField *h = [NSTextField labelWithString:@[@"Game action",@"Keyboard",@"Controller source"][i]];
            h.font = [NSFont boldSystemFontOfSize:12]; h.frame = NSMakeRect((CGFloat[]){26,250,440}[i],596,210,20); [content addSubview:h];
        }
        NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(20,240,660,352)];
        scroll.hasVerticalScroller = YES; scroll.borderType = NSBezelBorder;
        NSView *rows = [[NSView alloc] initWithFrame:NSMakeRect(0,0,640,DM_CONTROL_COUNT*32+8)]; scroll.documentView = rows;
        _keys = [NSMutableArray new]; _buttons = [NSMutableArray new]; _flags = [NSMutableArray new];
        for (int i = 0; i < DM_CONTROL_COUNT; i++) {
            CGFloat y = (DM_CONTROL_COUNT-1-i)*32+4;
            NSTextField *label = [NSTextField labelWithString:controls_action_names()[i]]; label.frame=NSMakeRect(8,y+4,205,22); [rows addSubview:label];
            NSButton *key = [NSButton buttonWithTitle:@"" target:self action:@selector(capture:)]; key.tag=i; key.frame=NSMakeRect(222,y,170,28); [rows addSubview:key]; [_keys addObject:key];
            if (i < 16 || i == DM_CONTROL_SHAKE) {
                NSPopUpButton *button = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(410,y,216,28) pullsDown:NO];
                button.tag=_buttons.count; button.target=self; button.action=@selector(buttonChanged:);
                [button addItemsWithTitles:controls_source_names()]; [rows addSubview:button]; [_buttons addObject:button];
            } else { NSTextField *native = [NSTextField labelWithString:@"Analog stick"]; native.textColor=NSColor.secondaryLabelColor; native.frame=NSMakeRect(416,y+4,210,22); [rows addSubview:native]; }
        }
        [rows scrollPoint:NSMakePoint(0,rows.bounds.size.height)]; [content addSubview:scroll];
        NSArray *flags = @[@"Swap sticks",@"Invert left X",@"Invert left Y",@"Invert right X",@"Invert right Y",@"Use controller motion",@"Combine connected controllers as player 1 (Joy-Con halves)"];
        for (int i=0;i<7;i++) {
            NSButton *flag = [NSButton checkboxWithTitle:flags[i] target:self action:@selector(flagChanged:)]; flag.tag=i;
            flag.frame = i < 5 ? NSMakeRect(20+(i%3)*220,208-(i/3)*28,218,24) : NSMakeRect(20,152-(i-5)*28,650,24);
            [content addSubview:flag]; [_flags addObject:flag];
        }
        _status = [NSTextField wrappingLabelWithString:@""]; _status.frame=NSMakeRect(20,59,660,58); _status.font=[NSFont systemFontOfSize:11]; _status.textColor=NSColor.secondaryLabelColor; [content addSubview:_status];
        NSButton *reset=[NSButton buttonWithTitle:@"Restore Defaults" target:self action:@selector(reset:)]; reset.frame=NSMakeRect(20,18,150,30); [content addSubview:reset];
        NSButton *cancel=[NSButton buttonWithTitle:@"Cancel" target:self action:@selector(cancel:)]; cancel.frame=NSMakeRect(480,18,90,30); cancel.keyEquivalent=@"\e"; [content addSubview:cancel];
        NSButton *save=[NSButton buttonWithTitle:@"Save" target:self action:@selector(save:)]; save.frame=NSMakeRect(580,18,100,30); save.keyEquivalent=@"\r"; [content addSubview:save];
        [self.window center];
    }
    [self reload]; [self.window makeKeyAndOrderFront:nil];
    [_timer invalidate]; _timer=[NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(updateStatus) userInfo:nil repeats:YES];
}
@end
static DmControlsEditor *g_controls_editor;
static void controls_add_menu(NSMenu *app) {
    controls_load(); g_controls_editor = [DmControlsEditor new];
    NSMenuItem *item = [app addItemWithTitle:@"Controls…" action:@selector(showControls:) keyEquivalent:@","]; item.target=g_controls_editor;
    [app addItem:NSMenuItem.separatorItem];
}
