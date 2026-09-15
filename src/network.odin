package main

import "core:net"
import "core:fmt"
import "core:mem"

// Network protocol for Nexus Arena.
// Phase 1: Minimal bit-packed UDP protocol.
// - Client -> Server: Input packets
// - Server -> Client: Delta snapshots
//
// Future: Compression, delta encoding, prediction, lag compensation.

PROTOCOL_VERSION :: u8(1)
MAX_PACKET_SIZE :: 1400 // Safe UDP payload size

// Packet types
Packet_Type :: enum u8 {
	Invalid = 0,
	Client_Input = 1,       // Client -> Server: inputs for this tick
	Server_Snapshot = 2,    // Server -> Client: world state snapshot
	Server_Welcome = 3,     // Server -> Client: entity ID assignment
	Server_GameState = 4,   // Server -> Client: match state and scores (Phase 4)
}

// Client input packet
// Sent from client to server each tick (60Hz)
Client_Input_Packet :: struct {
	tick_id:     u32,  // Client tick ID
	move_fwd:    i8,   // Forward/back [-127, 127]
	move_str:    i8,   // Strafe [-127, 127]
	jump:        bool, // Jump button
	delta_yaw:   i16,  // Yaw delta * 1000 (milliradian precision)
	delta_pitch: i16,  // Pitch delta * 1000
	cast_spell:  u8,   // Phase 3: Spell button (Spell_ID)
}

// Wire size for client input (hand-packed, not sizeof due to alignment):
// Header: 2 bytes (version + type)
// tick_id: 4 bytes
// move_fwd, move_str: 2 bytes
// jump: 1 byte
// delta_yaw, delta_pitch: 4 bytes
// cast_spell: 1 byte
// Total: 2 + 4 + 2 + 1 + 4 + 1 = 14 bytes
CLIENT_INPUT_WIRE_SIZE :: 14

// Server snapshot packet
// Sent from server to clients at 20-30Hz (lower than tick rate)
Server_Snapshot_Packet :: struct {
	tick_id:      u32,                        // Server tick ID
	entity_count: u8,                         // Number of entities in this snapshot
	entities:     [MAX_ENTITIES]Snapshot_Entity, // Entity states
	
	// Phase 3: Projectiles
	projectile_count: u8,
	projectiles:      [32]Snapshot_Projectile,  // Active projectiles (capped for bandwidth)
}

// Server welcome packet
// Sent once when client connects to assign entity ID
Server_Welcome_Packet :: struct {
	your_entity_id: Entity_ID,  // The entity ID assigned to this client
}

// Entity state in snapshot
Snapshot_Entity :: struct {
	id:        Entity_ID, // Entity ID
	pos:       vec3,      // Position
	yaw:       f32,       // Yaw angle
	pitch:     f32,       // Pitch angle
	vel_z:     f32,       // Vertical velocity
	on_ground: bool,      // Ground flag
	
	// Phase 3: Resources
	health:    f32,
	mana:      f32,
	stamina:   f32,
	
	// Phase 4: Team
	team:      Team_ID,
}

// Projectile state in snapshot (Phase 3)
Snapshot_Projectile :: struct {
	id:       Projectile_ID,
	spell_id: Spell_ID,
	owner_id: Entity_ID,
	pos:      vec3,
	vel:      vec3,
	lifetime: f32,
	radius:   f32,
}

// Game state packet (Phase 4) - Match state and Obelisk info
// Sent at lower rate than snapshots (every 2-3 seconds or on state change)
Server_GameState_Packet :: struct {
	match_state:     u8,   // Match_State
	match_result:    u8,   // Match_Result
	alpha_essence:   f32,  // Team Alpha essence points
	beta_essence:    f32,  // Team Beta essence points
	match_time:      f32,  // Match time in seconds
	
	// Obelisk states (3 Obelisks)
	obelisk_states:  [MAX_OBELISKS]u8,       // Obelisk_State for each
	obelisk_owners:  [MAX_OBELISKS]u8,       // Team_ID for each
	obelisk_progress: [MAX_OBELISKS]f32,     // Capture progress [0, 1]
}

// Network endpoint
Network_Endpoint :: struct {
	socket:   net.UDP_Socket,
	bound:    bool,
	port:     u16,
}

// Initialize network endpoint
network_init :: proc(endpoint: ^Network_Endpoint, port: u16) -> bool {
	socket, err := net.make_bound_udp_socket(net.IP4_Any, int(port))
	if err != nil {
		fmt.eprintln("Failed to bind UDP socket:", err)
		return false
	}
	
	endpoint.socket = socket
	endpoint.bound = true
	endpoint.port = port
	
	// Set non-blocking
	net.set_blocking(socket, false)
	
	fmt.printf("Network endpoint bound to UDP port %d\n", port)
	return true
}

// Shutdown network endpoint
network_shutdown :: proc(endpoint: ^Network_Endpoint) {
	if endpoint.bound {
		net.close(endpoint.socket)
		endpoint.bound = false
	}
}

// Serialize client input packet to bytes
serialize_client_input :: proc(packet: ^Client_Input_Packet, buffer: []u8) -> int {
	if len(buffer) < CLIENT_INPUT_WIRE_SIZE {
		return 0
	}
	
	pos := 0
	buffer[pos] = u8(PROTOCOL_VERSION); pos += 1
	buffer[pos] = u8(Packet_Type.Client_Input); pos += 1
	
	// Tick ID (4 bytes)
	mem.copy(&buffer[pos], &packet.tick_id, 4); pos += 4
	
	// Movement (2 bytes)
	buffer[pos] = transmute(u8)packet.move_fwd; pos += 1
	buffer[pos] = transmute(u8)packet.move_str; pos += 1
	
	// Jump (1 byte)
	buffer[pos] = packet.jump ? 1 : 0; pos += 1
	
	// Look deltas (4 bytes)
	mem.copy(&buffer[pos], &packet.delta_yaw, 2); pos += 2
	mem.copy(&buffer[pos], &packet.delta_pitch, 2); pos += 2
	
	// Phase 3: Cast spell (1 byte)
	buffer[pos] = packet.cast_spell; pos += 1
	
	return pos
}

// Deserialize client input packet from bytes
deserialize_client_input :: proc(buffer: []u8) -> (packet: Client_Input_Packet, ok: bool) {
	if len(buffer) < CLIENT_INPUT_WIRE_SIZE {
		return {}, false
	}
	
	pos := 0
	version := buffer[pos]; pos += 1
	if version != PROTOCOL_VERSION {
		return {}, false
	}
	
	ptype := Packet_Type(buffer[pos]); pos += 1
	if ptype != .Client_Input {
		return {}, false
	}
	
	mem.copy(&packet.tick_id, &buffer[pos], 4); pos += 4
	packet.move_fwd = transmute(i8)buffer[pos]; pos += 1
	packet.move_str = transmute(i8)buffer[pos]; pos += 1
	packet.jump = buffer[pos] != 0; pos += 1
	mem.copy(&packet.delta_yaw, &buffer[pos], 2); pos += 2
	mem.copy(&packet.delta_pitch, &buffer[pos], 2); pos += 2
	packet.cast_spell = buffer[pos]; pos += 1  // Phase 3
	
	return packet, true
}

// Serialize server snapshot to bytes
// Size budget breakdown (must fit in MAX_PACKET_SIZE = 1400 bytes):
//   Header: 2 bytes (version + type)
//   Tick ID: 4 bytes
//   Entity count: 1 byte
//   Per entity: 42 bytes (id=4, pos=12, yaw=4, pitch=4, vel_z=4, on_ground=1, health=4, mana=4, stamina=4, team=1)
//   Projectile count: 1 byte
//   Per projectile: 41 bytes (id=4, spell_id=1, owner=4, pos=12, vel=12, lifetime=4, radius=4)
//
// Max entities: (1400 - 2 - 4 - 1 - 1) / 42 = ~33 entities (conservatively cap at 28)
// With 28 entities (1176 bytes), room for ~5 projectiles (205 bytes) = 1388 bytes total
// Strategy: prioritize closest entities to viewer (future); for now, truncate at capacity
serialize_server_snapshot :: proc(packet: ^Server_Snapshot_Packet, buffer: []u8) -> int {
	if len(buffer) < MAX_PACKET_SIZE {
		return 0
	}
	
	// Calculate safe limits to fit in MAX_PACKET_SIZE
	HEADER_SIZE :: 2 + 4 + 1  // version, type, tick_id, entity_count
	ENTITY_SIZE :: 42  // Actual wire size (see breakdown above)
	PROJECTILE_HEADER :: 1  // projectile_count byte
	PROJECTILE_SIZE :: 41
	
	MAX_ENTITIES_IN_PACKET :: 28  // Leaves room for projectiles
	MAX_PROJECTILES_IN_PACKET :: 8
	
	// Cap entity count to fit in packet
	capped_entity_count := min(int(packet.entity_count), MAX_ENTITIES_IN_PACKET)
	
	// Calculate remaining space for projectiles
	used := HEADER_SIZE + capped_entity_count * ENTITY_SIZE + PROJECTILE_HEADER
	remaining := MAX_PACKET_SIZE - used
	max_projectiles := remaining / PROJECTILE_SIZE
	capped_projectile_count := min(int(packet.projectile_count), max_projectiles, MAX_PROJECTILES_IN_PACKET)
	
	pos := 0
	buffer[pos] = u8(PROTOCOL_VERSION); pos += 1
	buffer[pos] = u8(Packet_Type.Server_Snapshot); pos += 1
	
	// Tick ID (4 bytes)
	mem.copy(&buffer[pos], &packet.tick_id, 4); pos += 4
	
	// Entity count (1 byte) - capped
	buffer[pos] = u8(capped_entity_count); pos += 1
	
	// Entity data
	for i in 0..<capped_entity_count {
		entity := &packet.entities[i]
		
		// Entity ID (4 bytes)
		mem.copy(&buffer[pos], &entity.id, 4); pos += 4
		
		// Position (12 bytes)
		mem.copy(&buffer[pos], &entity.pos, 12); pos += 12
		
		// Angles (8 bytes)
		mem.copy(&buffer[pos], &entity.yaw, 4); pos += 4
		mem.copy(&buffer[pos], &entity.pitch, 4); pos += 4
		
		// Velocity Z (4 bytes)
		mem.copy(&buffer[pos], &entity.vel_z, 4); pos += 4
		
		// Flags (1 byte)
		buffer[pos] = entity.on_ground ? 1 : 0; pos += 1
		
		// Phase 3: Resources (12 bytes)
		mem.copy(&buffer[pos], &entity.health, 4); pos += 4
		mem.copy(&buffer[pos], &entity.mana, 4); pos += 4
		mem.copy(&buffer[pos], &entity.stamina, 4); pos += 4
		
		// Phase 4: Team (1 byte)
		buffer[pos] = u8(entity.team); pos += 1
	}
	
	// Phase 3: Projectile count (1 byte) - capped
	buffer[pos] = u8(capped_projectile_count); pos += 1
	
	// Phase 3: Projectile data (41 bytes each)
	for i in 0..<capped_projectile_count {
		proj := &packet.projectiles[i]
		
		mem.copy(&buffer[pos], &proj.id, 4); pos += 4
		buffer[pos] = u8(proj.spell_id); pos += 1
		mem.copy(&buffer[pos], &proj.owner_id, 4); pos += 4
		mem.copy(&buffer[pos], &proj.pos, 12); pos += 12
		mem.copy(&buffer[pos], &proj.vel, 12); pos += 12
		mem.copy(&buffer[pos], &proj.lifetime, 4); pos += 4
		mem.copy(&buffer[pos], &proj.radius, 4); pos += 4
	}
	
	return pos
}

// Send packet to address
network_send :: proc(endpoint: ^Network_Endpoint, buffer: []u8, size: int, to: net.Endpoint) -> bool {
	if !endpoint.bound || size <= 0 {
		return false
	}
	
	_, err := net.send_udp(endpoint.socket, buffer[:size], to)
	return err == nil
}

// Serialize welcome packet
serialize_server_welcome :: proc(packet: ^Server_Welcome_Packet, buffer: []u8) -> int {
	if len(buffer) < 7 {
		return 0
	}
	
	pos := 0
	buffer[pos] = u8(PROTOCOL_VERSION); pos += 1
	buffer[pos] = u8(Packet_Type.Server_Welcome); pos += 1
	
	// Entity ID (4 bytes)
	mem.copy(&buffer[pos], &packet.your_entity_id, 4); pos += 4
	
	return pos
}

// Serialize game state packet (Phase 4)
serialize_server_gamestate :: proc(packet: ^Server_GameState_Packet, buffer: []u8) -> int {
	if len(buffer) < 64 {
		return 0
	}
	
	pos := 0
	buffer[pos] = u8(PROTOCOL_VERSION); pos += 1
	buffer[pos] = u8(Packet_Type.Server_GameState); pos += 1
	
	// Match state (2 bytes)
	buffer[pos] = packet.match_state; pos += 1
	buffer[pos] = packet.match_result; pos += 1
	
	// Essence (8 bytes)
	mem.copy(&buffer[pos], &packet.alpha_essence, 4); pos += 4
	mem.copy(&buffer[pos], &packet.beta_essence, 4); pos += 4
	
	// Match time (4 bytes)
	mem.copy(&buffer[pos], &packet.match_time, 4); pos += 4
	
	// Obelisk states (3 bytes)
	for i in 0..<MAX_OBELISKS {
		buffer[pos] = packet.obelisk_states[i]; pos += 1
	}
	
	// Obelisk owners (3 bytes)
	for i in 0..<MAX_OBELISKS {
		buffer[pos] = packet.obelisk_owners[i]; pos += 1
	}
	
	// Obelisk progress (12 bytes)
	for i in 0..<MAX_OBELISKS {
		mem.copy(&buffer[pos], &packet.obelisk_progress[i], 4); pos += 4
	}
	
	return pos
}

// Receive packet (non-blocking)
network_receive :: proc(endpoint: ^Network_Endpoint, buffer: []u8) -> (bytes_read: int, from: net.Endpoint, ok: bool) {
	if !endpoint.bound {
		return 0, {}, false
	}
	
	n, ep, err := net.recv_udp(endpoint.socket, buffer)
	if err != nil {
		return 0, {}, false
	}
	
	return n, ep, true
}

// Convert input state to network packet format
input_to_packet :: proc(input: Input_State, tick_id: u32) -> Client_Input_Packet {
	return Client_Input_Packet{
		tick_id = tick_id,
		move_fwd = i8(clampf(input.move_fwd, -1, 1) * 127),
		move_str = i8(clampf(input.move_str, -1, 1) * 127),
		jump = input.jump,
		delta_yaw = i16(input.delta_yaw * 1000),
		delta_pitch = i16(input.delta_pitch * 1000),
		cast_spell = u8(input.cast_spell),  // Phase 3
	}
}

// Convert network packet to input state
packet_to_input :: proc(packet: Client_Input_Packet) -> Input_State {
	return Input_State{
		move_fwd = f32(packet.move_fwd) / 127.0,
		move_str = f32(packet.move_str) / 127.0,
		jump = packet.jump,
		delta_yaw = f32(packet.delta_yaw) / 1000.0,
		delta_pitch = f32(packet.delta_pitch) / 1000.0,
		cast_spell = Spell_ID(packet.cast_spell),  // Phase 3
	}
}
