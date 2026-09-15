package main

// Combat test client with aim and spell casting

import "core:fmt"
import "core:time"
import "core:math"

main :: proc() {
	fmt.println("=== Nexus Arena Combat Test Client ===")
	fmt.println("Testing spell casting with aim under ~80ms lag\n")
	
	// Initialize network
	client := Network_Client{}
	if !network_client_init(&client, "localhost", 27015) {
		fmt.eprintln("Failed to connect to server")
		return
	}
	defer network_client_shutdown(&client)
	
	// Latency simulation (80ms RTT = 40ms one-way)
	network_client_sim_latency(&client, 40, 0.02)
	fmt.println("Network: 40ms latency, 2% packet loss")
	
	// Wait for welcome packet
	fmt.println("Waiting for entity ID assignment...")
	local_id := Entity_ID(0)
	start := time.tick_now()
	
	for time.duration_seconds(time.tick_since(start)) < 5 {
		snapshot, welcome, ptype, ok := network_client_receive(&client)
		if ok && ptype == .Server_Welcome {
			local_id = welcome.your_entity_id
			fmt.printf("✓ Assigned entity ID: %d\n\n", local_id)
			break
		}
		time.sleep(10 * time.Millisecond)
	}
	
	if local_id == 0 {
		fmt.eprintln("❌ Failed to get entity ID (server not responding)")
		return
	}
	
	// Initialize client world
	client_world := client_world_init()
	client_world.local_entity_id = local_id
	
	// Get initial position by waiting for first snapshot
	fmt.println("Waiting for initial position...")
	for i in 0..<100 {
		snapshot, welcome, ptype, ok := network_client_receive(&client)
		if ok && ptype == .Server_Snapshot {
			client_world_apply_snapshot(&client_world, snapshot)
			if client_world.prediction.predicted_char.active {
				fmt.printf("✓ Position: (%.1f, %.1f, %.1f)\n", 
					client_world.prediction.predicted_char.pos.x,
					client_world.prediction.predicted_char.pos.y,
					client_world.prediction.predicted_char.pos.z)
				break
			}
		}
		time.sleep(10 * time.Millisecond)
	}
	
	// Find nearest bot to target
	fmt.println("\nScanning for bot targets...")
	time.sleep(200 * time.Millisecond)
	
	// Receive snapshots to get bot positions
	for i in 0..<50 {
		snapshot, welcome, ptype, ok := network_client_receive(&client)
		if ok && ptype == .Server_Snapshot {
			client_world_apply_snapshot(&client_world, snapshot)
		}
		time.sleep(10 * time.Millisecond)
	}
	
	// Find closest remote entity
	local_pos := client_world.prediction.predicted_char.pos
	closest_id := Entity_ID(0)
	closest_dist := f32(999999)
	
	for i in 1..<MAX_ENTITIES {
		if !client_world.remote_entities[i].active {
			continue
		}
		
		remote_pos := client_world.remote_entities[i].display_state.pos
		dx := remote_pos.x - local_pos.x
		dy := remote_pos.y - local_pos.y
		dist := math.sqrt(dx*dx + dy*dy)
		
		if dist < closest_dist {
			closest_dist = dist
			closest_id = Entity_ID(i)
		}
	}
	
	if closest_id == 0 {
		fmt.println("❌ No bot targets found")
		return
	}
	
	target_pos := client_world.remote_entities[closest_id].display_state.pos
	fmt.printf("✓ Target locked: Bot %d at (%.1f, %.1f, %.1f), distance: %.1fm\n\n",
		closest_id, target_pos.x, target_pos.y, target_pos.z, closest_dist)
	
	// Calculate aim angles to target
	dx := target_pos.x - local_pos.x
	dy := target_pos.y - local_pos.y
	dz := target_pos.z - local_pos.z + CHARACTER_HEIGHT_M * 0.5  // Aim at center mass
	
	target_yaw := math.atan2(dy, dx)
	horiz_dist := math.sqrt(dx*dx + dy*dy)
	target_pitch := math.atan2(dz, horiz_dist)
	
	fmt.printf("Aim angles: yaw=%.2f°, pitch=%.2f°\n", 
		target_yaw * 180 / math.PI, target_pitch * 180 / math.PI)
	
	// Set aim
	client_world.prediction.predicted_char.yaw = target_yaw
	client_world.prediction.predicted_char.pitch = target_pitch
	
	// Test sequence
	fmt.println("\n=== Combat Test Sequence ===\n")
	
	tick_id := u32(100)
	
	// Test 1: Arcane Missile (fast projectile)
	fmt.println("1. Casting Arcane Missile (fast projectile, 25 dmg)...")
	input := Input_State{
		delta_yaw = 0,
		delta_pitch = 0,
		cast_spell = .Arcane_Missile,
	}
	network_client_send_input(&client, tick_id, input)
	tick_id += 1
	
	// Wait for projectile to spawn and travel
	time.sleep(500 * time.Millisecond)
	
	// Check for projectile in snapshots
	projectile_seen := false
	for i in 0..<20 {
		snapshot, welcome, ptype, ok := network_client_receive(&client)
		if ok && ptype == .Server_Snapshot {
			if snapshot.projectile_count > 0 {
				projectile_seen = true
				fmt.printf("   ✓ Projectile visible: %d active\n", snapshot.projectile_count)
				break
			}
		}
		time.sleep(10 * time.Millisecond)
	}
	
	if !projectile_seen {
		fmt.println("   ⚠ No projectiles visible in snapshots")
	}
	
	time.sleep(1000 * time.Millisecond)
	
	// Test 2: Arcane Orb (slow AoE)
	fmt.println("\n2. Casting Arcane Orb (slow AoE, 60 dmg, 3m blast)...")
	input.cast_spell = .Arcane_Orb
	network_client_send_input(&client, tick_id, input)
	tick_id += 1
	
	time.sleep(2000 * time.Millisecond)
	
	// Test 3: Frost Shard (with slow debuff)
	fmt.println("\n3. Casting Frost Shard (30 dmg + 50% slow)...")
	input.cast_spell = .Frost_Shard
	network_client_send_input(&client, tick_id, input)
	tick_id += 1
	
	time.sleep(1500 * time.Millisecond)
	
	// Test 4: Blink (teleport)
	fmt.println("\n4. Casting Blink (10m teleport)...")
	input.cast_spell = .Blink
	network_client_send_input(&client, tick_id, input)
	tick_id += 1
	
	time.sleep(500 * time.Millisecond)
	
	// Final snapshot check
	fmt.println("\n=== Final Status ===")
	for i in 0..<10 {
		snapshot, welcome, ptype, ok := network_client_receive(&client)
		if ok && ptype == .Server_Snapshot {
			client_world_apply_snapshot(&client_world, snapshot)
			
			// Check local resources
			local_char := client_world.prediction.predicted_char
			fmt.printf("Local resources: HP=%.0f, Mana=%.0f, Stamina=%.0f\n",
				local_char.health, local_char.mana, local_char.stamina)
			
			// Check projectiles
			fmt.printf("Active projectiles: %d\n", client_world.projectile_count)
			
			// Check if target is still alive
			if client_world.remote_entities[closest_id].active {
				target_hp := client_world.remote_entities[closest_id].display_state.health
				fmt.printf("Target Bot %d: HP=%.0f\n", closest_id, target_hp)
			}
			break
		}
		time.sleep(10 * time.Millisecond)
	}
	
	fmt.println("\n✅ Combat test complete")
	fmt.println("Check server logs for hit confirmation:")
	fmt.println("  grep 'Combat.*hit' /tmp/combat_server.log")
}
