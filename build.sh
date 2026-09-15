#!/bin/bash
# Build script for Nexus Arena (Linux/Unix)
# Usage: ./build.sh [server|client|both] [run]

set -e

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ODIN_BIN="${ODIN_ROOT}/odin"
OUT_DIR="$ROOT/bin"
SRC_DIR="$ROOT/src"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

if [ ! -x "$ODIN_BIN" ]; then
    echo -e "${RED}Error: Odin compiler not found at $ODIN_BIN${NC}"
    echo -e "Set ODIN_ROOT environment variable to Odin installation directory"
    exit 1
fi

echo -e "${GREEN}=== Building Nexus Arena ===${NC}"

# Create output directory
mkdir -p "$OUT_DIR"

BUILD_MODE="${1:-both}"

# Build headless server
if [ "$BUILD_MODE" = "server" ] || [ "$BUILD_MODE" = "both" ]; then
    echo -e "${YELLOW}>> Building headless server...${NC}"

    TMP_SRC="$OUT_DIR/server_src"
    rm -rf "$TMP_SRC"
    mkdir -p "$TMP_SRC"

    # Copy server files
    for f in "$SRC_DIR"/*.odin; do
        base=$(basename "$f")
        # Exclude client-only files, combat test, and persistence (unless ENABLE_PERSISTENCE=1)
        if [[ "$base" != "render.odin" && "$base" != "input.odin" && "$base" != "scene.odin" && \
              "$base" != "main.odin" && "$base" != "player.odin" && "$base" != "camera.odin" && \
              "$base" != "main_client.odin" && "$base" != "client_renderer.odin" && "$base" != "main_test_client.odin" && \
              "$base" != "main_combat_test.odin" && \
              "$base" != "postgres.odin" && "$base" != "persistence.odin" ]]; then
            cp "$f" "$TMP_SRC/"
        fi
    done

    mv "$TMP_SRC/main_server.odin" "$TMP_SRC/main.odin" 2>/dev/null || true

    $ODIN_BIN build "$TMP_SRC" -out:"$OUT_DIR/nexus_server" ${BUILD_FLAGS:--debug}
    rm -rf "$TMP_SRC"

    echo -e "${GREEN}✓ Server built${NC}"
fi

# Build headless test client
if [ "$BUILD_MODE" = "client" ] || [ "$BUILD_MODE" = "both" ]; then
    echo -e "${YELLOW}>> Building headless test client...${NC}"

    TMP_SRC="$OUT_DIR/client_src"
    rm -rf "$TMP_SRC"
    mkdir -p "$TMP_SRC"

    # Copy client files
    for f in "$SRC_DIR"/*.odin; do
        base=$(basename "$f")
        # Exclude server and render files and combat test
        if [[ "$base" != "render.odin" && "$base" != "input.odin" && "$base" != "scene.odin" && \
              "$base" != "main.odin" && "$base" != "player.odin" && "$base" != "camera.odin" && \
              "$base" != "main_client.odin" && "$base" != "client_renderer.odin" && \
              "$base" != "main_server.odin" && "$base" != "server.odin" && "$base" != "camera_minimal.odin" && \
              "$base" != "main_combat_test.odin" ]]; then
            cp "$f" "$TMP_SRC/"
        fi
    done

    mv "$TMP_SRC/main_test_client.odin" "$TMP_SRC/main.odin" 2>/dev/null || true

    $ODIN_BIN build "$TMP_SRC" -out:"$OUT_DIR/nexus_client_test" ${BUILD_FLAGS:--debug}
    rm -rf "$TMP_SRC"

    echo -e "${GREEN}✓ Test client built${NC}"
fi

echo -e "${GREEN}>> Build complete!${NC}"
[ "$BUILD_MODE" = "server" ] || [ "$BUILD_MODE" = "both" ] && echo -e "  Server: $OUT_DIR/nexus_server"
[ "$BUILD_MODE" = "client" ] || [ "$BUILD_MODE" = "both" ] && echo -e "  Test Client: $OUT_DIR/nexus_client_test"

# Run if requested
if [ "${2:-}" == "run" ]; then
    if [ "$BUILD_MODE" = "server" ]; then
        echo -e "\n${GREEN}>> Running server...${NC}\n"
        exec "$OUT_DIR/nexus_server"
    elif [ "$BUILD_MODE" = "client" ]; then
        echo -e "\n${GREEN}>> Running test client...${NC}\n"
        exec "$OUT_DIR/nexus_client_test"
    fi
fi
