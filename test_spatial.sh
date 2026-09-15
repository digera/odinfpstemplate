#!/bin/bash
# Test Phase 5: Spatial Grid + Chunk Streaming

set -e

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}=== Phase 5: Spatial & Chunk Test ===${NC}"
echo ""

# Build test
echo -e "${YELLOW}>> Building spatial test...${NC}"
mkdir -p /tmp/nexus_spatial_test

# Copy necessary files
cp src/math.odin /tmp/nexus_spatial_test/
cp src/world_pos.odin /tmp/nexus_spatial_test/
cp src/entity.odin /tmp/nexus_spatial_test/
cp src/spatial_grid.odin /tmp/nexus_spatial_test/
cp src/chunk_streaming.odin /tmp/nexus_spatial_test/
cp src/teams.odin /tmp/nexus_spatial_test/  # entity.odin depends on this

# Create test main
cat > /tmp/nexus_spatial_test/main.odin << 'EOF'
package main

import "core:fmt"

main :: proc() {
	fmt.println("=== Spatial Grid & Chunk Streaming Test ===")
	
	// Test 1: World positions
	fmt.println("\n[Test 1] World position conversion...")
	arena_pos := vec3{8.0, 8.0, 0.0}
	world_pos := world_pos_from_vec3(arena_pos)
	fmt.printf("  Arena pos (%.1f, %.1f, %.1f) →\n", arena_pos.x, arena_pos.y, arena_pos.z)
	fmt.printf("  World pos: chunk(%d, %d, %d) + local(%.1f, %.1f, %.1f)\n",
		world_pos.chunk_x, world_pos.chunk_y, world_pos.chunk_z,
		world_pos.local_x, world_pos.local_y, world_pos.local_z)
	
	back_to_vec := world_pos_to_vec3(world_pos)
	if back_to_vec.x == arena_pos.x && back_to_vec.y == arena_pos.y && back_to_vec.z == arena_pos.z {
		fmt.println("✓ Round-trip conversion successful")
	} else {
		fmt.println("✗ Round-trip conversion failed")
		return
	}
	
	// Test 2: Spatial grid
	fmt.println("\n[Test 2] Spatial grid query...")
	grid := spatial_grid_init(.Single_Chunk)
	
	// Create test entities
	entity_world := entity_world_init()
	e1 := entity_spawn(&entity_world, vec3{5.0, 5.0, 0.0})
	e2 := entity_spawn(&entity_world, vec3{10.0, 10.0, 0.0})
	e3 := entity_spawn(&entity_world, vec3{50.0, 50.0, 0.0})
	
	fmt.printf("  Spawned 3 entities at (5,5), (10,10), (50,50)\n")
	
	// Query radius 10 from (5, 5)
	results := spatial_grid_query_radius(&grid, &entity_world, vec3{5.0, 5.0, 0.0}, 10.0)
	fmt.printf("  Query radius 10 from (5,5): found %d entities\n", len(results))
	
	if len(results) == 2 {
		fmt.println("✓ Spatial query found correct entities")
	} else {
		fmt.printf("✗ Expected 2 entities, found %d\n", len(results))
		return
	}
	
	// Test 3: Chunk streaming
	fmt.println("\n[Test 3] Chunk streaming...")
	cs := chunk_streaming_init("/tmp/nexus_chunks")
	defer chunk_streaming_shutdown(&cs)
	
	// Load chunks
	chunk1 := Chunk_ID{0, 0, 0}
	chunk2 := Chunk_ID{1, 0, 0}
	chunk3 := Chunk_ID{0, 1, 0}
	
	if !chunk_load(&cs, chunk1) {
		fmt.println("✗ Failed to load chunk (0,0,0)")
		return
	}
	if !chunk_load(&cs, chunk2) {
		fmt.println("✗ Failed to load chunk (1,0,0)")
		return
	}
	if !chunk_load(&cs, chunk3) {
		fmt.println("✗ Failed to load chunk (0,1,0)")
		return
	}
	
	fmt.println("✓ Loaded 3 chunks")
	
	// Check loaded
	if !chunk_is_loaded(&cs, chunk1) {
		fmt.println("✗ Chunk (0,0,0) not loaded")
		return
	}
	
	// Get chunks in radius
	nearby := chunk_get_in_radius(&cs, chunk1, 1)
	fmt.printf("  Chunks in radius 1 from (0,0,0): %d chunks\n", len(nearby))
	
	if len(nearby) > 0 {
		fmt.println("✓ Chunk radius query works")
	}
	
	// Save chunk
	if !chunk_save(&cs, chunk1) {
		fmt.println("✗ Failed to save chunk")
		return
	}
	fmt.println("✓ Saved chunk (0,0,0)")
	
	// Unload
	chunk_unload(&cs, chunk2)
	if chunk_is_loaded(&cs, chunk2) {
		fmt.println("✗ Chunk still loaded after unload")
		return
	}
	fmt.println("✓ Unloaded chunk (1,0,0)")
	
	fmt.println("\n=== ALL TESTS PASSED ===")
}
EOF

# Compile test
odin build /tmp/nexus_spatial_test -out:/tmp/nexus_spatial_test_bin -o:speed 2>&1 | grep -E "(Error|Warning)" || true

if [ ! -f /tmp/nexus_spatial_test_bin ]; then
    echo -e "${RED}✗ Build failed${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Build successful${NC}"
echo ""

# Run test
echo -e "${YELLOW}>> Running spatial test...${NC}"
/tmp/nexus_spatial_test_bin

echo ""
echo -e "${GREEN}=== Spatial Test PASSED ===${NC}"
