#!/bin/bash
# Build script for graphical Nexus Arena client
# Requires: X11, OpenGL, ALSA (Linux desktop environment)

set -e

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ODIN_BIN="${ODIN_ROOT}/odin"
OUT_DIR="$ROOT/bin"
SRC_DIR="$ROOT/src"
SOKOL_PATH="$ROOT/third_party/sokol-odin/sokol"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [ ! -x "$ODIN_BIN" ]; then
    echo -e "${RED}Error: Odin compiler not found at $ODIN_BIN${NC}"
    echo -e "Set ODIN_ROOT environment variable"
    exit 1
fi

if [ ! -d "$SOKOL_PATH" ]; then
    echo -e "${RED}Error: sokol-odin not found at $SOKOL_PATH${NC}"
    echo -e "Run: git clone https://github.com/floooh/sokol-odin.git third_party/sokol-odin"
    exit 1
fi

if [ ! -f "$SOKOL_PATH/app/sokol_app_linux_x64_gl_release.a" ]; then
    echo -e "${YELLOW}>> Building sokol C libraries...${NC}"
    cd "$SOKOL_PATH" && ./build_clibs_linux.sh
    cd "$ROOT"
fi

echo -e "${GREEN}=== Building Nexus Arena Graphical Client ===${NC}"

# Compile shaders if needed
if [ ! -f "$SRC_DIR/scene.odin" ] || [ "$SRC_DIR/../shaders/scene.glsl" -nt "$SRC_DIR/scene.odin" ]; then
    echo -e "${YELLOW}>> Compiling shaders...${NC}"
    sokol-shdc -i shaders/scene.glsl -o src/scene.odin -l glsl430:metal_macos:wgsl -f sokol_odin
fi

mkdir -p "$OUT_DIR"

echo -e "${YELLOW}>> Building graphical client...${NC}"

TMP_SRC="$OUT_DIR/gfx_client_src"
rm -rf "$TMP_SRC"
mkdir -p "$TMP_SRC"

# Copy client files (exclude server and original template files)
for f in "$SRC_DIR"/*.odin; do
    base=$(basename "$f")
    # Exclude: server files, test client, conflicting template files, main.odin
    # Keep: input.odin (needed for main_client), scene.odin (shader bindings), room.odin (for room_inside)
    if [[ "$base" != "main.odin" && "$base" != "main_server.odin" && "$base" != "server.odin" && \
          "$base" != "main_test_client.odin" && "$base" != "main_combat_test.odin" && "$base" != "camera_minimal.odin" && \
          "$base" != "camera.odin" && "$base" != "player.odin" && "$base" != "render.odin" ]]; then
        cp "$f" "$TMP_SRC/"
    fi
done

# Build with sokol collection
$ODIN_BIN build "$TMP_SRC" \
    -out:"$OUT_DIR/nexus_client" \
    -collection:sokol="$SOKOL_PATH" \
    -extra-linker-flags:"-lGL -lX11 -lXi -lXcursor -lasound -lpthread -lm -ldl" \
    ${BUILD_FLAGS:--debug}

rm -rf "$TMP_SRC"

echo -e "${GREEN}✓ Graphical client built: $OUT_DIR/nexus_client${NC}"
echo ""
echo -e "${YELLOW}Note:${NC} This client requires an X11 display and OpenGL."
echo -e "To run on a headless server, use SSH with X11 forwarding or a virtual display (Xvfb)."
echo ""
echo -e "Run with: ${GREEN}./bin/nexus_client${NC}"
