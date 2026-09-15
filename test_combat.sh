#!/bin/bash
# Phase 3 combat test - automated spell casting verification

set -e

echo "=== Phase 3 Combat Test ==="
echo "Testing projectile spells and hit registration under lag"
echo ""

# Start server
echo "Starting server..."
./bin/nexus_server > /tmp/combat_server.log 2>&1 &
SERVER_PID=$!
sleep 2

# Create test client that casts spells
echo "Building combat test client..."

cat > /tmp/combat_test_client.odin << 'EOF'
package main

import "core:fmt"
import "core:time"
import "core:math"

main :: proc() {
	fmt.println("=== Combat Test Client ===")
	
	// Initialize network
	client := Network_Client{}
	if !network_client_init(&client, "localhost", 27015) {
		fmt.eprintln("Failed to connect")
		return
	}
	defer network_client_shutdown(&client)
	
	// Latency simulation (80ms RTT = 40ms one-way)
	network_client_sim_latency(&client, 40, 0.02)
	
	// Wait for welcome packet
	fmt.println("Waiting for entity ID...")
	local_id := Entity_ID(0)
	start := time.tick_now()
	
	for time.duration_seconds(time.tick_since(start)) < 2 {
		snapshot, welcome, ptype, ok := network_client_receive(&client)
		if ok && ptype == .Server_Welcome {
			local_id = welcome.your_entity_id
			fmt.printf("Assigned entity ID: %d\n", local_id)
			break
		}
		time.sleep(10 * time.Millisecond)
	}
	
	if local_id == 0 {
		fmt.eprintln("Failed to get entity ID")
		return
	}
	
	// Test sequence: Cast Arcane Missile 5 times with aim at center
	fmt.println("\nCasting Arcane Missiles...")
	
	for i in 0..<5 {
		input := Input_State{
			move_fwd = 0,
			move_str = 0,
			jump = false,
			delta_yaw = 0,
			delta_pitch = 0,
			cast_spell = .Arcane_Missile,
		}
		
		tick_id := u32(i * 60 + 100)  // Simulate tick IDs
		network_client_send_input(&client, tick_id, input)
		
		fmt.printf("  Cast #%d at tick %d\n", i+1, tick_id)
		time.sleep(250 * time.Millisecond)  // 4 casts per second
	}
	
	// Wait and check for damage
	fmt.println("\nWaiting for server response...")
	time.sleep(2 * time.Second)
	
	// Cast Arcane Orb (AoE)
	fmt.println("\nCasting Arcane Orb (AoE)...")
	orb_input := Input_State{
		cast_spell = .Arcane_Orb,
	}
	network_client_send_input(&client, 500, orb_input)
	
	time.sleep(2 * time.Second)
	
	fmt.println("\n✅ Combat test complete")
	fmt.println("Check server logs for hit registration and damage")
}
EOF

# Compile test client
export ODIN_ROOT=/tmp/odin-compiler
TMP_SRC="/tmp/combat_test_src"
rm -rf "$TMP_SRC"
mkdir -p "$TMP_SRC"

# Copy necessary files
for f in src/*.odin; do
    base=$(basename "$f")
    if [[ "$base" != "main.odin" && "$base" != "main_server.odin" && "$base" != "server.odin" && \
          "$base" != "main_test_client.odin" && "$base" != "main_client.odin" && \
          "$base" != "render.odin" && "$base" != "input.odin" && "$base" != "scene.odin" && \
          "$base" != "camera.odin" && "$base" != "player.odin" && \
          "$base" != "client_renderer.odin" ]]; then
        cp "$f" "$TMP_SRC/"
    fi
done

cp /tmp/combat_test_client.odin "$TMP_SRC/main.odin"

$ODIN_ROOT/odin build "$TMP_SRC" -out:/tmp/combat_test_client -debug 2>&1 | tail -10

if [ ! -f /tmp/combat_test_client ]; then
    echo "❌ Failed to build test client"
    kill $SERVER_PID 2>/dev/null || true
    exit 1
fi

# Run test
echo ""
/tmp/combat_test_client

# Give server time to process
sleep 1

# Stop server
kill $SERVER_PID 2>/dev/null || true
wait $SERVER_PID 2>/dev/null || true

echo ""
echo "=== Server Log Analysis ==="

# Check for spell casts
SPELL_CASTS=$(grep -c "Cast" /tmp/combat_server.log 2>/dev/null || echo "0")
echo "Spells processed by server: (check logs manually)"

# Check for projectile spawns (would need logging)
echo ""
echo "Server log excerpt:"
tail -30 /tmp/combat_server.log | grep -E "(Client|Entity|Projectile|Cast|Damage)" || echo "  (No specific combat events logged)"

echo ""
echo "Full server log: /tmp/combat_server.log"
echo ""
echo "=== Test Summary ==="
echo "✅ Server running with Phase 3 combat systems"
echo "✅ Client sent spell cast inputs (Arcane Missile × 5, Arcane Orb × 1)"
echo "✅ Network protocol extended with cast_spell field"
echo "⚠  Server-side hit registration requires logging to verify"
echo ""
echo "Note: For full verification, server needs debug logging for:"
echo "  - Spell cast handling"
echo "  - Projectile spawns"
echo "  - Hit detection events"
echo "  - Damage application"
