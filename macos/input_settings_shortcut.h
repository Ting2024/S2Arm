// Adapted from MacNativeGames input_settings_shortcut_macos.h.
// Match physical comma even with a non-Latin input method; Command alone is not enough.
static inline BOOL s2a_input_settings_shortcut(NSEvent *event) {
    NSEventModifierFlags flags = event.modifierFlags &
        (NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption | NSEventModifierFlagShift);
    return event.type == NSEventTypeKeyDown && flags == NSEventModifierFlagCommand &&
        (event.keyCode == 43 || [event.charactersIgnoringModifiers isEqualToString:@","]);
}
