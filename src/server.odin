package main

import "core:fmt"
import "core:time"
import "core:math"
import "core:math/rand"
import "core:net"
import "core:os"
import "core:strconv"

// Headless dedicated server for Nexus Arena.
// Phase 1 Goals:
// - Fixed 60Hz deterministic tick
// - ~16 bot entities with jump/strafe behavior
// - Measure tick time and verify stability
// - Network scaffold ready (but bots don't need network yet)

Server :: struct {
	world:           Entity_World,
	network:         Network_Endpoint,
	tick_id:         u32,
	running:         bool,
	bot_count:       int,
	bot_ids:         [16]Entity_ID,
	
	// Performance metrics
	tick_times_ms:   [60]f32,  // Rolling window of tick times
	tick_idx:        int,
	total_ticks:     u64,
	start_time:      time.Tick,
	
	// Network state
	connected_clients:     [MAX_CLIENTS]net.Endpoint,
	client_entity_ids:     [MAX_CLIENTS]Entity_ID,  // Entity ID for each client
	client_last_packet:    [MAX_CLIENTS]time.Tick,  // Last packet time for disconnect timeout
	client_count:          int,
	last_snapshot_tick:    u32,
	
	// Phase 3: Combat systems
	projectiles:     Projectile_World,
	lag_comp:        Lag_Comp_State,
	
	// Phase 4: Dominion systems
	obelisks:        Obelisk_World,
	match:           Match,
	last_gamestate_tick: u32,
}

MAX_CLIENTS :: 16
SNAPSHOT_RATE :: 30  // Send snapshots at 30Hz (every 2 ticks at 60Hz)

// Bot AI state
Bot_AI :: struct {
	think_timer:   f32,
	move_dir:      f32,  // Target movement direction
	strafe_dir:    f32,  // Target strafe direction
	jump_timer:    f32,
	turn_speed:    f32,
	target_yaw:    f32,
}

bot_ais: [16]Bot_AI

// Initialize server
server_init :: proc(port: u16, bot_count: int) -> (server: Server, ok: bool) {
	fmt.println("=== Nexus Arena Headless Server ===")
	fmt.printf("Initializing server on port %d with %d bots...\n", port, bot_count)
	
	server.world = entity_world_init()
	server.bot_count = min(bot_count, 16)
	server.start_time = time.tick_now()
	
	// Phase 3: Initialize combat systems
	server.projectiles = projectile_world_init()
	server.lag_comp = lag_comp_init()
	
	// Phase 4: Initialize Dominion systems
	server.obelisks = obelisk_world_init()
	server.match = match_init()
	
	// Check for test mode environment variables
	// NEXUS_TEST_ESSENCE=50 ./bin/nexus_server
	// NEXUS_TEST_FAST=10 ./bin/nexus_server (10x essence generation)
	{
		buf: [64]u8
		test_essence := os.get_env_buf(buf[:], "NEXUS_TEST_ESSENCE")
		if test_essence != "" {
			threshold, ok_threshold := strconv.parse_f32(test_essence)
			if ok_threshold && threshold > 0 {
				match_configure_test_mode(threshold, test_essence_multiplier)
			}
		}
	}
	
	{
		buf: [64]u8
		test_fast := os.get_env_buf(buf[:], "NEXUS_TEST_FAST")
		if test_fast != "" {
			multiplier, ok_mult := strconv.parse_f32(test_fast)
			if ok_mult && multiplier > 0 {
				match_configure_test_mode(test_essence_threshold, multiplier)
			}
		}
	}
	
	// Initialize network (optional for Phase 1 bot testing)
	if port > 0 {
		if !network_init(&server.network, port) {
			fmt.eprintln("Warning: Network initialization failed, running offline")
		}
	}
	
	// Spawn bots on teams
	fmt.printf("Spawning %d bots on teams...\n", server.bot_count)
	for i in 0..<server.bot_count {
		// Assign bots to teams (alternating)
		team := i % 2 == 0 ? Team_ID.Alpha : Team_ID.Beta
		
		// Spawn bots in team areas
		angle := f32(i) * (2.0 * math.PI / f32(server.bot_count))
		radius := f32(4.0)
		center := (ROOM_MIN + ROOM_MAX) * 0.5
		
		// Alpha on south side, Beta on north side
		offset := team == .Alpha ? vec3{-2, -2, 0} : vec3{2, 2, 0}
		
		pos := vec3{
			center.x + math.cos(angle) * radius + offset.x,
			center.y + math.sin(angle) * radius + offset.y,
			ROOM_MIN.z,
		}
		
		bot_id := entity_spawn(&server.world, pos, team)
		if bot_id == INVALID_ENTITY {
			fmt.eprintf("Failed to spawn bot %d\n", i)
			continue
		}
		
		server.bot_ids[i] = bot_id
		
		// Initialize bot AI
		bot_ais[i] = Bot_AI{
			move_dir = rand.float32_range(-1, 1),
			strafe_dir = rand.float32_range(-1, 1),
			jump_timer = rand.float32_range(0, 2),
			turn_speed = rand.float32_range(0.5, 2.0),
			target_yaw = rand.float32_range(0, 2.0 * math.PI),
		}
		
		// Set initial yaw
		idx, ok := entity_get_character_mut(&server.world, bot_id)
		if ok {
			server.world.characters[idx].yaw = bot_ais[i].target_yaw
		}
	}
	
	fmt.printf("Server initialized: %d bots spawned (%d Alpha, %d Beta), %d entities active\n", 
		server.bot_count, (server.bot_count+1)/2, server.bot_count/2, server.world.count)
	
	server.running = true
	return server, true
}

// Update bot AI for one tick
server_update_bot_ai :: proc(server: ^Server, bot_idx: int, dt: f32) {
	if bot_idx >= server.bot_count {
		return
	}
	
	bot_id := server.bot_ids[bot_idx]
	char, ok := entity_get_character(&server.world, bot_id)
	if !ok {
		return
	}
	
	ai := &bot_ais[bot_idx]
	bot_team := entity_get_team(&server.world, bot_id)
	
	// Phase 4: Obelisk-seeking AI
	// Find nearest Obelisk that is not held by our team
	target_obelisk: ^Obelisk = nil
	min_dist_sq := f32(999999)
	
	for i in 0..<server.obelisks.count {
		obelisk := &server.obelisks.obelisks[i]
		
		// Skip if already held by our team (defend less priority than capture)
		if obelisk.state == .Held && obelisk.owner == bot_team {
			continue
		}
		
		// Calculate distance
		dx := obelisk.pos.x - char.pos.x
		dy := obelisk.pos.y - char.pos.y
		dist_sq := dx*dx + dy*dy
		
		if dist_sq < min_dist_sq {
			min_dist_sq = dist_sq
			target_obelisk = obelisk
		}
	}
	
	// Move toward target Obelisk
	move_fwd: f32 = 1.0  // Always move forward
	move_str: f32 = 0
	target_yaw := char.yaw
	
	if target_obelisk != nil {
		// Calculate direction to Obelisk
		dx := target_obelisk.pos.x - char.pos.x
		dy := target_obelisk.pos.y - char.pos.y
		
		target_yaw = math.atan2(dy, dx)
		
		// Move forward if not at Obelisk
		if min_dist_sq > OBELISK_RADIUS * OBELISK_RADIUS * 0.5 {
			move_fwd = 1.0
		} else {
			// At Obelisk, stand still to capture
			move_fwd = 0.5  // Slow movement to stay in capture zone
		}
	} else {
		// Fallback: random movement if no objective (shouldn't happen)
		ai.think_timer -= dt
		if ai.think_timer <= 0 {
			ai.think_timer = rand.float32_range(2.0, 4.0)
			ai.target_yaw = rand.float32_range(0, 2.0 * math.PI)
		}
		target_yaw = ai.target_yaw
		move_fwd = 1.0
	}
	
	// Smooth turn toward target yaw
	yaw_diff := target_yaw - char.yaw
	// Normalize to [-PI, PI]
	for yaw_diff > math.PI {
		yaw_diff -= 2.0 * math.PI
	}
	for yaw_diff < -math.PI {
		yaw_diff += 2.0 * math.PI
	}
	
	delta_yaw := clampf(yaw_diff * 2.0 * dt, -0.15, 0.15)
	
	// Jump occasionally for movement (less than before)
	ai.jump_timer -= dt
	should_jump := false
	if ai.jump_timer <= 0 && char.on_ground {
		ai.jump_timer = rand.float32_range(2.0, 4.0)
		should_jump = rand.float32() < 0.3  // 30% chance
	}
	
	// Set input for this bot
	input := Input_State{
		move_fwd = move_fwd,
		move_str = move_str,
		jump = should_jump,
		delta_yaw = delta_yaw,
		delta_pitch = 0,
	}
	
	// Debug: Log first bot's target every 120 ticks (2 seconds)
	if bot_idx == 0 && server.tick_id % 120 == 0 && target_obelisk != nil {
		fmt.printf("[Bot AI] Bot 0 → Obelisk %d at (%.1f, %.1f), dist=%.1fm, moving=%.1f\n",
			target_obelisk.id, target_obelisk.pos.x, target_obelisk.pos.y, 
			math.sqrt(min_dist_sq), move_fwd)
	}
	
	entity_set_input(&server.world, bot_id, input)
}

// Run one server tick
server_tick :: proc(server: ^Server) {
	tick_start := time.tick_now()
	
	// Process incoming packets
	server_process_packets(server)
	
	// Check for client timeouts (5 second silence = disconnect)
	CLIENT_TIMEOUT_SEC :: 5.0
	for i := 0; i < server.client_count; {
		elapsed := time.duration_seconds(time.tick_diff(server.client_last_packet[i], time.tick_now()))
		
		if elapsed > CLIENT_TIMEOUT_SEC {
			// Client timed out, disconnect
			entity_id := server.client_entity_ids[i]
			fmt.printf("[Server] Client %v timed out (%.1fs silence), disconnecting entity %d\n", 
				server.connected_clients[i], elapsed, entity_id)
			
			// Despawn entity
			if entity_id != INVALID_ENTITY {
				server.world.characters[entity_id].active = false
			}
			
			// Remove client from list (swap with last)
			last_idx := server.client_count - 1
			if i != last_idx {
				server.connected_clients[i] = server.connected_clients[last_idx]
				server.client_entity_ids[i] = server.client_entity_ids[last_idx]
				server.client_last_packet[i] = server.client_last_packet[last_idx]
			}
			server.client_count -= 1
			// Don't increment i, check this slot again (now contains the old last element)
		} else {
			i += 1
		}
	}
	
	// Update bot AI
	for i in 0..<server.bot_count {
		server_update_bot_ai(server, i, SIMULATION_DT)
	}
	
	// Phase 3: Update spell cooldowns and regenerate resources
	server_update_resources(server, SIMULATION_DT)
	
	// Death/respawn system (playtesting)
	entity_tick_death_respawn(&server.world, SIMULATION_DT)
	
	// Run simulation step (deterministic kernel)
	simulate_world_step(&server.world)
	
	// Phase 3: Update projectiles
	projectile_tick(&server.projectiles, &server.world, SIMULATION_DT)
	
	// Phase 4: Update Obelisks and match state
	obelisk_tick(&server.obelisks, &server.world, SIMULATION_DT)
	match_tick(&server.match, &server.obelisks, SIMULATION_DT)
	
	// Phase 3: Record entity positions for lag compensation
	for i in 1..<MAX_ENTITIES {
		if server.world.characters[i].active {
			lag_comp_record(&server.lag_comp, Entity_ID(i), server.world.characters[i].pos, server.tick_id)
		}
	}
	
	// Send snapshots to clients (30Hz = every 2 ticks)
	if server.tick_id % 2 == 0 {
		server_send_snapshots(server)
	}
	
	// Phase 4: Send game state updates (slower rate, every 60 ticks = 1 second)
	if server.tick_id % 60 == 0 {
		server_send_gamestate(server)
	}
	
	server.tick_id += 1
	server.total_ticks += 1
	
	// Record tick time
	tick_duration := time.tick_since(tick_start)
	tick_ms := f32(time.duration_milliseconds(tick_duration))
	server.tick_times_ms[server.tick_idx] = tick_ms
	server.tick_idx = (server.tick_idx + 1) % len(server.tick_times_ms)
}

// Process incoming network packets
server_process_packets :: proc(server: ^Server) {
	buffer: [MAX_PACKET_SIZE]u8
	
	// Process up to 100 packets per tick
	for i in 0..<100 {
		n, from, ok := network_receive(&server.network, buffer[:])
		if !ok || n < 2 {
			break
		}
		
		// Check packet type
		if n < 2 {
			continue
		}
		
		ptype := Packet_Type(buffer[1])
		
		if ptype == .Client_Input {
			// Register client if new (spawns entity and sends welcome)
			entity_id, is_new := server_register_client(server, from)
			
			// If this is a new connection, send welcome packet
			if is_new && entity_id != INVALID_ENTITY {
				server_send_welcome(server, from, entity_id)
			}
			
			// Phase 3: Process input packet and apply to player entity
			if entity_id != INVALID_ENTITY {
				input_packet, input_ok := deserialize_client_input(buffer[:n])
				if input_ok {
					input := packet_to_input(input_packet)
					server.world.inputs[entity_id] = input
					
					// Handle spell casting
					if input.cast_spell != .None {
						server_handle_spell_cast(server, entity_id, input.cast_spell, input_packet.tick_id)
					}
				}
			}
		}
	}
}

// Register a client connection and spawn player entity
server_register_client :: proc(server: ^Server, client_addr: net.Endpoint) -> (entity_id: Entity_ID, is_new: bool) {
	// Check if already registered (match full endpoint: address + port)
	for i in 0..<server.client_count {
		registered := &server.connected_clients[i]
		// Compare address and port
		if registered.address == client_addr.address && registered.port == client_addr.port {
			// Already registered, update last packet time and return existing entity ID
			server.client_last_packet[i] = time.tick_now()
			return server.client_entity_ids[i], false
		}
	}
	
	// Add new client
	if server.client_count < MAX_CLIENTS {
		// Assign team (balance teams)
		alpha_count := 0
		beta_count := 0
		for i in 0..<server.client_count {
			team := entity_get_team(&server.world, server.client_entity_ids[i])
			if team == .Alpha {
				alpha_count += 1
			} else if team == .Beta {
				beta_count += 1
			}
		}
		
		// Assign to team with fewer players
		client_team := alpha_count <= beta_count ? Team_ID.Alpha : Team_ID.Beta
		
		// Spawn player entity for this client on their team
		// Place players in team areas (Alpha south, Beta north)
		angle := f32(server.client_count) * (2.0 * math.PI / f32(MAX_CLIENTS))
		radius := f32(6.0)  // Slightly larger radius than bots
		center := (ROOM_MIN + ROOM_MAX) * 0.5
		
		// Team-based offset
		offset := client_team == .Alpha ? vec3{-2, -2, 0} : vec3{2, 2, 0}
		
		spawn_pos := vec3{
			center.x + math.cos(angle) * radius + offset.x,
			center.y + math.sin(angle) * radius + offset.y,
			ROOM_MIN.z,
		}
		
		player_id := entity_spawn(&server.world, spawn_pos, client_team)
		if player_id == INVALID_ENTITY {
			fmt.eprintf("[Server] Failed to spawn player entity for client\n")
			return INVALID_ENTITY, false
		}
		
		// Register client
		idx := server.client_count
		server.connected_clients[idx] = client_addr
		server.client_entity_ids[idx] = player_id
		server.client_last_packet[idx] = time.tick_now()  // Initialize last packet time
		server.client_count += 1
		
		fmt.printf("[Server] Client connected: %v → Entity ID %d, Team %s (total clients: %d)\n", 
			client_addr, player_id, team_name(client_team), server.client_count)
		
		return player_id, true
	}
	
	return INVALID_ENTITY, false
}

// Send welcome packet to client with their entity ID
server_send_welcome :: proc(server: ^Server, client_addr: net.Endpoint, entity_id: Entity_ID) {
	welcome := Server_Welcome_Packet{
		your_entity_id = entity_id,
	}
	
	buffer: [MAX_PACKET_SIZE]u8
	size := serialize_server_welcome(&welcome, buffer[:])
	if size > 0 {
		network_send(&server.network, buffer[:], size, client_addr)
		fmt.printf("[Server] Sent welcome to client: Entity ID %d\n", entity_id)
	}
}

// Send world snapshot to all connected clients
server_send_snapshots :: proc(server: ^Server) {
	if server.client_count == 0 {
		return
	}
	
	// Build snapshot packet
	snapshot := Server_Snapshot_Packet{
		tick_id = server.tick_id,
		entity_count = 0,
		projectile_count = 0,
	}
	
	// Add all active entities
	for i in 1..<MAX_ENTITIES {
		if !server.world.characters[i].active {
			continue
		}
		
		if int(snapshot.entity_count) >= MAX_ENTITIES {
			break
		}
		
		char := server.world.characters[i]
		snapshot.entities[snapshot.entity_count] = Snapshot_Entity{
			id = Entity_ID(i),
			pos = char.pos,
			yaw = char.yaw,
			pitch = char.pitch,
			vel_z = char.vel_z,
			on_ground = char.on_ground,
			// Phase 3: Resources
			health = char.health,
			mana = char.mana,
			stamina = char.stamina,
			// Phase 4: Team
			team = server.world.teams[i],
		}
		snapshot.entity_count += 1
	}
	
	// Phase 3: Add active projectiles (cap at 32 for bandwidth)
	for i in 0..<MAX_PROJECTILES {
		if !server.projectiles.projectiles[i].active {
			continue
		}
		
		if int(snapshot.projectile_count) >= 32 {
			break
		}
		
		proj := server.projectiles.projectiles[i]
		snapshot.projectiles[snapshot.projectile_count] = Snapshot_Projectile{
			id = proj.id,
			spell_id = proj.spell_id,
			owner_id = proj.owner_id,
			pos = proj.pos,
			vel = proj.vel,
			lifetime = proj.lifetime,
			radius = proj.radius,
		}
		snapshot.projectile_count += 1
	}
	
	// Serialize
	buffer: [MAX_PACKET_SIZE]u8
	size := serialize_server_snapshot(&snapshot, buffer[:])
	if size <= 0 {
		return
	}
	
	// Send to all clients
	for i in 0..<server.client_count {
		network_send(&server.network, buffer[:], size, server.connected_clients[i])
	}
}

// Send game state update (Phase 4: Dominion)
server_send_gamestate :: proc(server: ^Server) {
	if server.client_count == 0 {
		return
	}
	
	// Build game state packet
	gamestate := Server_GameState_Packet{
		match_state = u8(server.match.state),
		match_result = u8(server.match.result),
		alpha_essence = server.match.alpha_essence,
		beta_essence = server.match.beta_essence,
		match_time = server.match.match_time,
	}
	
	// Add Obelisk states
	for i in 0..<MAX_OBELISKS {
		obelisk := &server.obelisks.obelisks[i]
		gamestate.obelisk_states[i] = u8(obelisk.state)
		gamestate.obelisk_owners[i] = u8(obelisk.owner)
		gamestate.obelisk_progress[i] = obelisk.capture_progress
	}
	
	// Serialize
	buffer: [MAX_PACKET_SIZE]u8
	size := serialize_server_gamestate(&gamestate, buffer[:])
	if size <= 0 {
		return
	}
	
	// Send to all clients
	for i in 0..<server.client_count {
		network_send(&server.network, buffer[:], size, server.connected_clients[i])
	}
}

// Get average tick time
server_avg_tick_time :: proc(server: ^Server) -> f32 {
	sum: f32 = 0
	count := min(int(server.total_ticks), len(server.tick_times_ms))
	if count == 0 {
		return 0
	}
	
	for i in 0..<count {
		sum += server.tick_times_ms[i]
	}
	
	return sum / f32(count)
}

// Get max tick time
server_max_tick_time :: proc(server: ^Server) -> f32 {
	max_time: f32 = 0
	count := min(int(server.total_ticks), len(server.tick_times_ms))
	
	for i in 0..<count {
		max_time = max(max_time, server.tick_times_ms[i])
	}
	
	return max_time
}

// Main server loop
server_run :: proc(server: ^Server) {
	fmt.println("\n=== Starting server tick loop (60Hz) ===")
	fmt.println("Press Ctrl+C to stop\n")
	
	tick_interval := time.Duration(1_000_000_000 / SIMULATION_TICK_RATE) // 16.666ms
	next_tick := time.tick_now()
	last_stats := time.tick_now()
	
	for server.running {
		now := time.tick_now()
		
		// Run tick if it's time
		if time.tick_since(next_tick) >= 0 {
			server_tick(server)
			next_tick._nsec += i64(tick_interval)
			
			// Detect tick overrun
			if time.tick_since(next_tick) >= tick_interval {
				fmt.eprintf("WARNING: Tick overrun! Server falling behind.\n")
				next_tick = time.tick_now()
			}
		}
		
		// Print stats every 5 seconds
		if time.tick_since(last_stats) >= time.Second * 5 {
			server_print_stats(server)
			last_stats = time.tick_now()
		}
		
		// Sleep briefly to avoid busy-wait
		time.sleep(time.Millisecond)
	}
	
	fmt.println("\nServer shutting down...")
	server_shutdown(server)
}

// Print server statistics
server_print_stats :: proc(server: ^Server) {
	uptime := time.tick_since(server.start_time)
	uptime_sec := f64(uptime) / f64(time.Second)
	
	avg_tick := server_avg_tick_time(server)
	max_tick := server_max_tick_time(server)
	
	fmt.printf("[Server Stats] Uptime: %.1fs | Ticks: %d | Entities: %d | Clients: %d | Avg tick: %.3fms | Max tick: %.3fms\n",
		uptime_sec, server.total_ticks, server.world.count, server.client_count, avg_tick, max_tick)
	
	// Print first few bot positions for verification
	fmt.printf("  Bot positions: ")
	for i in 0..<min(3, server.bot_count) {
		char, ok := entity_get_character(&server.world, server.bot_ids[i])
		if ok {
			fmt.printf("B%d=(%.2f,%.2f,%.2f) ", i, char.pos.x, char.pos.y, char.pos.z)
		}
	}
	fmt.println()
}

// Shutdown server
server_shutdown :: proc(server: ^Server) {
	server.running = false
	network_shutdown(&server.network)
	fmt.println("Server stopped.")
}

// Phase 3: Update resource pools and cooldowns
server_update_resources :: proc(server: ^Server, dt: f32) {
	for i in 1..<MAX_ENTITIES {
		if !server.world.characters[i].active {
			continue
		}
		
		char := &server.world.characters[i]
		spell_state := &server.world.spell_states[i]
		
		// Regenerate mana
		char.mana = min(char.mana + MANA_REGEN_PER_SEC * dt, MANA_MAX)
		
		// Regenerate stamina
		char.stamina = min(char.stamina + STAMINA_REGEN_PER_SEC * dt, STAMINA_MAX)
		
		// Update cooldowns
		for spell_id in Spell_ID {
			if spell_state.cooldowns[spell_id] > 0 {
				spell_state.cooldowns[spell_id] -= dt
				if spell_state.cooldowns[spell_id] < 0 {
					spell_state.cooldowns[spell_id] = 0
				}
			}
		}
	}
}

// Phase 3: Handle spell cast attempt
server_handle_spell_cast :: proc(server: ^Server, caster_id: Entity_ID, spell_id: Spell_ID, client_tick: u32) {
	if caster_id >= MAX_ENTITIES || !server.world.characters[caster_id].active {
		return
	}
	
	// B5: Validate Spell_ID from wire (must be in valid range and implemented)
	if int(spell_id) < 0 || int(spell_id) >= len(SPELL_DEFS) {
		fmt.printf("[Combat] Invalid Spell_ID %d from entity %d\n", spell_id, caster_id)
		return
	}
	
	// Get spell definition
	def := &SPELL_DEFS[spell_id]
	if def.payload == .None {
		// Stub spell with no implementation (like Purifying_Beam)
		// Do not consume mana or set cooldown for unimplemented spells
		fmt.printf("[Combat] Entity %d: %s not implemented (stub payload)\n", caster_id, def.name)
		return
	}
	
	char := &server.world.characters[caster_id]
	spell_state := &server.world.spell_states[caster_id]
	
	// Check cooldown
	if spell_state.cooldowns[spell_id] > 0 {
		fmt.printf("[Combat] Entity %d: %s on cooldown (%.1fs remaining)\n", 
			caster_id, def.name, spell_state.cooldowns[spell_id])
		return  // On cooldown
	}
	
	// Check mana cost
	if char.mana < def.mana_cost {
		fmt.printf("[Combat] Entity %d: Not enough mana for %s (%.1f/%.1f)\n", 
			caster_id, def.name, char.mana, def.mana_cost)
		return  // Not enough mana
	}
	
	// B6: Clamp client_tick to sane window (within history size / ~1 second)
	// Prevent client from rewinding to arbitrary past/future
	MAX_REWIND_TICKS :: u32(60)  // 1 second at 60Hz
	clamped_tick := client_tick
	if server.tick_id > client_tick {
		// Client is in past (normal with latency)
		tick_delta := server.tick_id - client_tick
		if tick_delta > MAX_REWIND_TICKS {
			clamped_tick = server.tick_id - MAX_REWIND_TICKS
			fmt.printf("[Combat] Clamped rewind: client_tick %d → %d (delta %d > max %d)\n",
				client_tick, clamped_tick, tick_delta, MAX_REWIND_TICKS)
		}
	} else if client_tick > server.tick_id {
		// Client is in future (suspicious or clock desync)
		clamped_tick = server.tick_id
		fmt.printf("[Combat] Clamped future tick: client_tick %d → %d\n", client_tick, clamped_tick)
	}
	
	// Consume mana (only after all checks pass)
	char.mana -= def.mana_cost
	
	// Set cooldown
	spell_state.cooldowns[spell_id] = def.cooldown_sec
	
	fmt.printf("[Combat] Entity %d cast %s (mana: %.1f→%.1f, cooldown: %.1fs)\n",
		caster_id, def.name, char.mana + def.mana_cost, char.mana, def.cooldown_sec)
	
	// Build cast request (use clamped tick for lag comp)
	origin := vec3{char.pos.x, char.pos.y, char.pos.z + PLAYER_EYE_M}
	direction := camera_forward(char.yaw, char.pitch)
	
	spell_cast := Spell_Cast{
		caster_id = caster_id,
		spell_id  = spell_id,
		origin    = origin,
		direction = direction,
		tick      = clamped_tick,  // Use clamped tick, not raw client_tick
	}
	
	// Execute spell based on type
	switch def.payload {
	case .Projectile:
		// Spawn projectile
		proj_id := projectile_spawn(&server.projectiles, &spell_cast, def)
		fmt.printf("[Combat] Projectile spawned: ID %d, speed %.1fm/s, lifetime %.1fs\n",
			proj_id, def.proj_speed, def.proj_lifetime)
		
	case .Hitscan:
		// Perform lag-compensated hitscan
		hit, hit_entity, hit_pos := hitscan_check(
			&server.lag_comp,
			&server.world,
			caster_id,
			origin,
			direction,
			def.beam_range,
			clamped_tick,  // Use clamped tick for lag compensation rewind
		)
		
		if hit {
			// Apply damage
			old_health := server.world.characters[hit_entity].health
			server.world.characters[hit_entity].health -= def.damage
			fmt.printf("[Combat] Hitscan hit! Entity %d → Entity %d: %.1f damage (%.1f→%.1f HP)\n",
				caster_id, hit_entity, def.damage, old_health, server.world.characters[hit_entity].health)
		} else {
			fmt.printf("[Combat] Hitscan miss (range: %.1fm)\n", def.beam_range)
		}
		
	case .Teleport:
		// Blink
		if spell_id == .Blink {
			old_pos := char.pos
			// Move in facing direction
			blink_dir := norm_vec3(vec3{direction.x, direction.y, 0})  // Horizontal only
			new_pos := char.pos + blink_dir * def.beam_range
			
			// Clamp to room
			if room_inside(new_pos, CHARACTER_RADIUS_M) {
				char.pos = new_pos
				fmt.printf("[Combat] Blink: Entity %d teleported %.1fm\n",
					caster_id, len_vec3(new_pos - old_pos))
			} else {
				fmt.printf("[Combat] Blink: Entity %d blocked by wall\n", caster_id)
			}
		}
		
	case .Beam_Channel, .AoE_Instant, .None:
		// Not implemented in Phase 3
		fmt.printf("[Combat] Spell type not implemented: %v\n", def.payload)
	}
}

// Entry point for headless server
main_server :: proc() {
	// Configuration
	PORT :: 27015
	BOT_COUNT :: 16
	
	server, ok := server_init(PORT, BOT_COUNT)
	if !ok {
		fmt.eprintln("Failed to initialize server")
		return
	}
	
	server_run(&server)
}
