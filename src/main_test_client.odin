package main

// Headless client test
// Verifies prediction and network without rendering

import "core:fmt"
import "core:time"
import "core:math"

// Minimal camera functions needed for prediction
camera_forward :: proc(yaw, pitch: f32) -> vec3 {
	cp := math.cos(pitch)
	return {math.cos(yaw) * cp, math.sin(yaw) * cp, math.sin(pitch)}
}

camera_right :: proc(yaw: f32) -> vec3 {
	return {math.sin(yaw), -math.cos(yaw), 0}
}

Test_Client :: struct {
	network:        Network_Client,
	client_world:   Client_World,
	running:        bool,
	last_input_send: time.Tick,
	test_duration:  f64,
}

main :: proc() {
	fmt.println("=== Nexus Arena - Headless Client Test ===")
	fmt.println("Testing prediction and network without rendering\n")
	
	client := Test_Client{}
	
	// Initialize network client
	if !network_client_init(&client.network, "localhost", 27015) {
		fmt.eprintln("Failed to initialize network client")
		return
	}
	
	// Enable latency simulation (100ms RTT = 50ms one-way, 2% loss)
	network_client_sim_latency(&client.network, 50, 0.02)
	
	// Initialize client world
	client.client_world = client_world_init()
	
	// Spawn local player
	spawn_pos := vec3{8, 8, 0}  // Center of room
	local_char := Character_State{
		pos = spawn_pos,
		yaw = 0,
		pitch = 0,
		on_ground = true,
		active = true,
	}
	
	// Initialize prediction
	client_prediction_init(&client.client_world.prediction, local_char)
	
	// Mark as connecting
	client.network.state = .Connecting
	client.last_input_send = time.tick_now()
	client.running = true
	
	fmt.println("Client initialized, connecting to server...")
	fmt.println("Will run for 30 seconds testing prediction...\n")
	
	// Run test
	test_start := time.tick_now()
	tick_interval := time.Duration(1_000_000_000 / 60)  // 60Hz
	next_tick := time.tick_now()
	last_stats := time.tick_now()
	
	// Test input pattern (circle movement)
	angle: f32 = 0
	
	for client.running {
		now := time.tick_now()
		
		// Check duration
		elapsed := time.tick_since(test_start)
		client.test_duration = f64(elapsed) / f64(time.Second)
		if client.test_duration >= 30 {
			break
		}
		
		// Receive snapshots
		for i in 0..<10 {
			snapshot, welcome, ptype, ok := network_client_receive(&client.network)
			if !ok {
				break
			}
			
			// Handle welcome packet (entity ID assignment)
			if ptype == .Server_Welcome {
				client.client_world.local_entity_id = welcome.your_entity_id
				fmt.printf("[Test Client] Assigned entity ID: %d\n", welcome.your_entity_id)
				continue
			}
			
			// Handle snapshot packet
			if ptype == .Server_Snapshot {
				if client.network.state != .Connected {
					client.network.state = .Connected
					fmt.println("[Test Client] Connected to server\n")
				}
				
				// Apply snapshot
				client_world_apply_snapshot(&client.client_world, snapshot)
			}
		}
		
		// Send input at 60Hz
		if time.tick_since(next_tick) >= 0 {
			// Build test input (circle movement + periodic jumps)
			angle += 0.05
			input := Input_State{
				move_fwd = math.cos(angle),
				move_str = math.sin(angle),
				jump = (client.client_world.client_tick % 120 == 0),  // Jump every 2 seconds
				delta_yaw = 0.02,  // Slow turn
				delta_pitch = 0,
			}
			
			// Predict locally
			client.client_world.client_tick += 1
			client_prediction_step(&client.client_world.prediction, client.client_world.client_tick, input)
			
			// Send to server
			network_client_send_input(&client.network, client.client_world.client_tick, input)
			
			next_tick._nsec += i64(tick_interval)
		}
		
		// Update interpolation
		client_world_update_interpolation(&client.client_world, 3)
		
		// Print stats every 5 seconds
		if time.tick_since(last_stats) >= time.Second * 5 {
			test_client_print_stats(&client)
			last_stats = time.tick_now()
		}
		
		// Sleep briefly
		time.sleep(time.Millisecond)
	}
	
	// Final stats
	fmt.println("\n=== Test Complete ===")
	test_client_print_stats(&client)
	
	// Cleanup
	network_client_shutdown(&client.network)
}

test_client_print_stats :: proc(client: ^Test_Client) {
	local_char := client.client_world.prediction.predicted_char
	rate, total := client_prediction_stats(&client.client_world.prediction)
	sent, recv, rtt := network_client_stats(&client.network)
	
	remote_count := 0
	for i in 0..<MAX_ENTITIES {
		if client.client_world.remote_entities[i].active {
			remote_count += 1
		}
	}
	
	fmt.printf("[Stats @ %.1fs] Pos: (%.2f,%.2f,%.2f) | Predictions: %d (%.1f%% mispredict) | Network: %d/%d pkts, ~%.0fms RTT | Remotes: %d\n",
		client.test_duration,
		local_char.pos.x, local_char.pos.y, local_char.pos.z,
		total, rate * 100,
		sent, recv, rtt,
		remote_count)
}
