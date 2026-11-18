#!/bin/bash
# Independent controller transport/HID regression. No device access or game.
set -euo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
cd "$R"
source tools/toolchain.sh
export DOTNET_ROOT=${DOTNET_ROOT:-"$R/build/toolchains/dotnet"}
DOTNET=${DOTNET:-"$DOTNET_ROOT/dotnet"}
export DOTNET_TieredCompilation=0 DOTNET_CLI_TELEMETRY_OPTOUT=1
export CLANG_MODULE_CACHE_PATH="$R/build/macos/clang-cache"
OUT="$R/build/macos/player-input-tests"
mkdir -p "$OUT"
export S2A_TZDATA=${S2A_TZDATA:-"$OUT/tzdata"}
[ -f "$S2A_TZDATA/binaryList.txt" ] || bash services/systemdata/make_tzdata.sh "$S2A_TZDATA" > "$OUT/tzdata.log" 2>&1
xcrun clang -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined -Iruntime/include \
    runtime/tests/t_player_input_buffer.c runtime/src/player_input_buffer.c -o "$OUT/buffer"
xcrun clang -std=c11 -Wall -Wextra -Werror -dynamiclib -Iruntime/include \
    launchers/macos/Tests/player_input_bridge.c runtime/src/player_input_buffer.c runtime/src/player_input_map.c -o "$OUT/bridge.dylib"
xcrun clang -std=c11 -O1 -g -Wall -Wextra -Werror -fsanitize=address,undefined -Iruntime/include \
    runtime/tests/t_player_input_map.c runtime/src/player_input_map.c -o "$OUT/map"
xcrun clang -fobjc-arc -O1 -g -Wall -Wextra -Werror -fsanitize=address,undefined -Iruntime/include \
    launchers/macos/Tests/player_input_sample_test.m macos/player_input_sample.m \
    macos/controllers/S2ASystemControllerSlots.m macos/controllers/S2AControllerInput.m \
    macos/controllers/S2AControllerSlots.c runtime/src/input_config.c \
    runtime/src/player_input_map.c runtime/src/player_input_buffer.c -o "$OUT/sample" \
    -framework Foundation -framework GameController -framework IOKit
"$DOTNET" build services/S2A.Services.Tests -c Release --no-restore -v q > "$OUT/build.log" 2>&1 || {
    echo "Service build failed; inspect build/macos/player-input-tests/build.log"; exit 1;
}
# Fresh check before fixture execution. No installed App or game is launched.
ps -axo pid=,comm= | awk '/s2arm-host|S2ArmApple|S2ArmLauncher/ {print}'
for fixture in buffer map sample; do
    ps -axo pid=,comm= > "$OUT/pre-fixture-processes.log"
    "$OUT/$fixture"
done
export S2A_PLAYER_INPUT_TEST_BRIDGE="$OUT/bridge.dylib"
for mode in input-four-players input-sideways input-lifetime input-selfstop two-pads hostui-applets; do
    ps -axo pid=,comm= > "$OUT/pre-fixture-processes.log"
    if "$DOTNET" services/S2A.Services.Tests/bin/Release/net10.0/S2A.Services.Tests.dll "--$mode" > "$OUT/$mode.log" 2>&1; then
        echo "$mode: passed"
    else
        echo "$mode: failed; inspect build/macos/player-input-tests/$mode.log"; exit 1
    fi
done
grep 'Independent player HID:' "$OUT/input-four-players.log"
