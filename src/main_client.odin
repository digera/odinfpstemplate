package main

// Client entry point with prediction and rendering

import "core:fmt"
import "core:time"
import "core:math"
import "core:os"
import "base:runtime"
import sapp "sokol:app"
import slog "sokol:log"

Game_Client :: struct {
	// Network
	network:        Network_Client,
	connected:      bool,
	
	// Prediction
	client_world:   Client_World,
	
	// Rendering
	renderer:       Client_Renderer,
	
	// Input
	input_state:    Input_State,
	mouse_dx:       f32,
	mouse_dy:       f32,
	selected_spell: Spell_ID,
	
	// Timing
	last_input_send: time.Tick,
}

game_client: Game_Client

client_init :: proc "c" () {
	context = runtime.default_context()
	
	fmt.println("=== Nexus Arena Client ===")
	
	// Initialize network client
	if !network_client_init(&game_client.network, "localhost", 27015) {
		fmt.eprintln("Failed to initialize network client")
		return
	}
	
	// Disable artificial latency for playtesting (use real network latency)
	// For testing, set environment variable ENABLE_SIM_LATENCY=1
	env_buf: [256]u8
	env_val := os.get_env_buf(env_buf[:], "ENABLE_SIM_LATENCY")
	if env_val == "1" {
		network_client_sim_latency(&game_client.network, 50, 0.02)
		fmt.println("[Client] Artificial latency enabled (50ms, 2% loss)")
	}
	
	// Initialize client world
	game_client.client_world = client_world_init()
	
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
	client_prediction_init(&game_client.client_world.prediction, local_char)
	
	// Mark as connecting
	game_client.network.state = .Connecting
	game_client.last_input_send = time.tick_now()
	game_client.selected_spell = .Arcane_Missile  // Default spell
	
	// Initialize renderer
	client_renderer_init(&game_client.renderer)
	
	fmt.println("Client initialized, connecting to server...")
}

client_frame :: proc "c" () {
	context = runtime.default_context()
	
	frame_start := time.tick_now()
	dt := f32(sapp.frame_duration())
	
	// Handle input
	client_handle_input(&game_client, dt)
	
	// Receive packets from server (unified dispatcher)
	for i in 0..<10 {  // Process up to 10 packets per frame
		snapshot, welcome, gamestate, ptype, packet_ok := network_client_receive(&game_client.network)
		if !packet_ok {
			break
		}
		
		// Handle welcome packet (entity ID assignment)
		if ptype == .Server_Welcome {
			game_client.client_world.local_entity_id = welcome.your_entity_id
			fmt.printf("[Client] Assigned entity ID: %d\n", welcome.your_entity_id)
			continue
		}
		
		// Handle snapshot packet
		if ptype == .Server_Snapshot {
			if !game_client.connected {
				game_client.connected = true
				fmt.println("[Client] Connected to server")
			}
			
			// Apply snapshot
			client_world_apply_snapshot(&game_client.client_world, snapshot)
			
			// Extract our team from the snapshot (once)
			if game_client.client_world.local_team == .None {
				for j in 0..<int(snapshot.entity_count) {
					if snapshot.entities[j].id == game_client.client_world.local_entity_id {
						game_client.client_world.local_team = snapshot.entities[j].team
						fmt.printf("[Client] Joined Team %s\n", team_name(game_client.client_world.local_team))
						break
					}
				}
			}
		}
		
		// Handle game state packet
		if ptype == .Server_GameState {
			game_client.client_world.game_state = gamestate
		}
	}
	
	// Send input and simulate at 60Hz (with catch-up for long frames)
	send_interval := time.Duration(1_000_000_000 / 60)  // 16.67ms
	elapsed_since_last := time.tick_since(game_client.last_input_send)
	
	// Calculate how many ticks we should run (capped at 5 to avoid spiral of death)
	ticks_to_run := int(elapsed_since_last / send_interval)
	ticks_to_run = min(ticks_to_run, 5)
	
	for tick_i in 0..<ticks_to_run {
		// Build input from current state
		input := game_client.input_state
		input.delta_yaw = game_client.mouse_dx * CAM_LOOK_SENS
		input.delta_pitch = -game_client.mouse_dy * CAM_LOOK_SENS
		
		// Predict locally
		game_client.client_world.client_tick += 1
		client_prediction_step(&game_client.client_world.prediction, game_client.client_world.client_tick, input)
		
		// Send to server
		network_client_send_input(&game_client.network, game_client.client_world.client_tick, input)
		
		// Only reset mouse deltas after last tick
		if tick_i == ticks_to_run - 1 {
			game_client.mouse_dx = 0
			game_client.mouse_dy = 0
		}
	}
	
	if ticks_to_run > 0 {
		game_client.last_input_send = time.tick_now()
	}
	
	// Update remote entity interpolation (50ms delay = 3 ticks at 60Hz)
	client_world_update_interpolation(&game_client.client_world, 3)
	
	// Render
	client_renderer_draw(&game_client.renderer, &game_client.client_world)
}

client_cleanup :: proc "c" () {
	context = runtime.default_context()
	
	network_client_shutdown(&game_client.network)
	client_renderer_shutdown(&game_client.renderer)
	
	// Print stats
	rate, total := client_prediction_stats(&game_client.client_world.prediction)
	fmt.printf("[Client] Prediction stats: %.1f%% mispredictions (%d total)\n", rate * 100, total)
	
	sent, recv, rtt := network_client_stats(&game_client.network)
	fmt.printf("[Client] Network stats: %d sent, %d recv, ~%.1fms RTT\n", sent, recv, rtt)
}

client_handle_input :: proc(client: ^Game_Client, dt: f32) {
	// Handle mouse lock
	if !sapp.mouse_locked() {
		if input_consume_click() && input.window_focused {
			sapp.lock_mouse(true)
		}
		// Clear look delta if not locked
		_, _ = input_consume_look()
		return
	}
	
	// Get mouse look delta
	dx, dy := input_consume_look()
	client.mouse_dx += dx
	client.mouse_dy += dy
	
	// Build input state from keyboard
	fwd: f32 = 0
	str: f32 = 0
	
	if input.key_w {
		fwd += 1
	}
	if input.key_s {
		fwd -= 1
	}
	if input.key_d {
		str += 1
	}
	if input.key_a {
		str -= 1
	}
	
	// Normalize diagonal movement
	len := math.sqrt(fwd * fwd + str * str)
	if len > 0 {
		fwd /= len
		str /= len
	}
	
	client.input_state.move_fwd = fwd
	client.input_state.move_str = str
	client.input_state.jump = input_consume_jump()
	
	// Handle spell selection (keys 1-4)
	if input_consume_cast(1) {
		client.selected_spell = .Arcane_Missile
	}
	if input_consume_cast(2) {
		client.selected_spell = .Arcane_Orb
	}
	if input_consume_cast(3) {
		client.selected_spell = .Blink
	}
	if input_consume_cast(4) {
		client.selected_spell = .Frost_Shard
	}
	
	// Cast selected spell on left click
	if input.held_left {
		client.input_state.cast_spell = client.selected_spell
	} else {
		client.input_state.cast_spell = .None
	}
}

main_client :: proc() {
	sapp.run({
		init_cb       = client_init,
		frame_cb      = client_frame,
		cleanup_cb    = client_cleanup,
		event_cb      = input_event,
		width         = WINDOW_W,
		height        = WINDOW_H,
		sample_count  = 1,
		high_dpi      = false,
		window_title  = "Nexus Arena - Client",
		icon          = {sokol_default = true},
		logger        = {func = slog.func},
		swap_interval = 1,
	})
}

main :: proc() {
	main_client()
}
