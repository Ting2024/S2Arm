# MacNativeGames input migration

The files listed in `migration.json` are byte-for-byte copies of
`MacNativeGames/games/d3/runtime`, under the accompanying MIT license.
They are the migration source, not a second reimplementation. Source hashes
make local adapter edits distinguishable from the original implementation.

The original stack includes the four-port settings UI, immediate persistent
edits, source selection, physical keyboards, controller ownership, raw HID,
mouse controls, motion and rumble. Device reservations deliberately remain
offline when a GameController connection object changes; names are not IDs.

`runtime.h` is the S2Arm boundary declaration file, not the original game's
runtime. Integration must bind its configuration root to the captured session
and adapt the existing S2Arm HID ABI. Do not regenerate any independent game.

The migrated modules are not yet selected by the production host. Passing
configuration/device tests alone does not establish in-game four-player input.

`input.c` is retained as the original source reference, not compiled: its legacy
unassigned keyboard fallback is extracted at the adapter boundary. S2Arm keeps
its own guest HID service; game-specific automation and nn::hid exports are not
copied into that service. Default keyboard aliases, short edges, inactive
reservations, and configuration clears are exercised through the real producer
and S2Arm frame reader in `test_mng_adapter.py`.

The isolated candidate host now links, but is **not a production migration**:
worker root admission, old JSON settings compatibility, per-player feedback,
and user-registry identity compatibility remain integration gates. Root checks
are admission-time checks, not protection against a same-user process replacing
ancestor directories or changing the legacy configuration environment later.
