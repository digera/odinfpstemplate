package main

import "core:fmt"
import "core:net"
import "core:time"
import "core:mem"

// Network client for connecting to the game server

Client_State :: enum {
	Disconnected,
	Connecting,
	Connected,
}

Network_Client :: struct {
	endpoint:       Network_Endpoint,
	server_addr:    net.Endpoint,
	state:          Client_State,
	
	// Timing
	last_send_time: time.Tick,
	last_recv_time: time.Tick,
	
	// Statistics
	packets_sent:   int,
	packets_recv:   int,
	bytes_sent:     int,
	bytes_recv:     int,
	
	// Latency simulation
	sim_latency_ms: int,  // Artificial latency (one-way)
	sim_loss_rate:  f32,  // Packet loss rate (0.0-1.0)
}

// Initialize client
network_client_init :: proc(client: ^Network_Client, server_host: string, server_port: u16) -> bool {
	// Bind to any local port
	if !network_init(&client.endpoint, 0) {
		fmt.eprintln("Failed to initialize client network")
		return false
	}
	
	// Resolve server address
	// For now, assume server is localhost
	client.server_addr = net.Endpoint{
		address = net.IP4_Loopback,
		port = int(server_port),
	}
	
	client.state = .Disconnected
	client.last_send_time = time.tick_now()
	client.last_recv_time = time.tick_now()
	
	fmt.printf("Client initialized, server: %v:%d\n", server_host, server_port)
	return true
}

// Shutdown client
network_client_shutdown :: proc(client: ^Network_Client) {
	network_shutdown(&client.endpoint)
	client.state = .Disconnected
}

// Send input packet to server
network_client_send_input :: proc(client: ^Network_Client, tick_id: u32, input: Input_State) -> bool {
	if client.state != .Connected && client.state != .Connecting {
		return false
	}
	
	// Simulate packet loss
	if client.sim_loss_rate > 0 {
		// Simple loss simulation (not cryptographically random, but good enough)
		loss_check := f32(hash_u32(u32(tick_id)) & 0xFFFF) / 65536.0
		if loss_check < client.sim_loss_rate {
			// Drop packet
			return true
		}
	}
	
	// Build packet
	packet := input_to_packet(input, tick_id)
	
	// Serialize
	buffer: [MAX_PACKET_SIZE]u8
	size := serialize_client_input(&packet, buffer[:])
	if size <= 0 {
		return false
	}
	
	// Send (with simulated latency handled externally via delay queue)
	if network_send(&client.endpoint, buffer[:], size, client.server_addr) {
		client.packets_sent += 1
		client.bytes_sent += size
		client.last_send_time = time.tick_now()
		return true
	}
	
	return false
}

// Receive packet from server (unified dispatcher for all packet types)
network_client_receive :: proc(client: ^Network_Client) -> (snapshot: Server_Snapshot_Packet, welcome: Server_Welcome_Packet, gamestate: Server_GameState_Packet, packet_type: Packet_Type, ok: bool) {
	buffer: [MAX_PACKET_SIZE]u8
	
	n, from, recv_ok := network_receive(&client.endpoint, buffer[:])
	if !recv_ok || n < 2 {
		return {}, {}, {}, .Invalid, false
	}
	
	client.packets_recv += 1
	client.bytes_recv += n
	client.last_recv_time = time.tick_now()
	
	// Check packet type
	if n < 2 {
		return {}, {}, {}, .Invalid, false
	}
	
	version := buffer[0]
	if version != PROTOCOL_VERSION {
		return {}, {}, {}, .Invalid, false
	}
	
	ptype := Packet_Type(buffer[1])
	
	if ptype == .Server_Snapshot {
		// Deserialize snapshot
		snap, snap_ok := deserialize_server_snapshot(buffer[:n])
		if snap_ok && client.state == .Connecting {
			client.state = .Connected
		}
		return snap, {}, {}, ptype, snap_ok
	} else if ptype == .Server_Welcome {
		// Deserialize welcome (entity ID assignment)
		if n < 6 {
			return {}, {}, {}, .Invalid, false
		}
		
		welcome_packet := Server_Welcome_Packet{}
		mem.copy(&welcome_packet.your_entity_id, &buffer[2], 4)
		
		if client.state == .Connecting {
			client.state = .Connected
		}
		
		return {}, welcome_packet, {}, ptype, true
	} else if ptype == .Server_GameState {
		// Deserialize game state
		gs, gs_ok := deserialize_server_gamestate(buffer[:n])
		return {}, {}, gs, ptype, gs_ok
	}
	
	return {}, {}, {}, .Invalid, false
}

// Deserialize server snapshot from bytes
deserialize_server_snapshot :: proc(buffer: []u8) -> (packet: Server_Snapshot_Packet, ok: bool) {
	if len(buffer) < 7 {
		return {}, false
	}
	
	pos := 0
	version := buffer[pos]; pos += 1
	if version != PROTOCOL_VERSION {
		return {}, false
	}
	
	ptype := Packet_Type(buffer[pos]); pos += 1
	if ptype != .Server_Snapshot {
		return {}, false
	}
	
	// Tick ID (4 bytes)
	mem.copy(&packet.tick_id, &buffer[pos], 4); pos += 4
	
	// Entity count (1 byte) - cap to MAX_ENTITIES
	entity_count_raw := buffer[pos]; pos += 1
	packet.entity_count = min(entity_count_raw, u8(MAX_ENTITIES))
	
	// Entity data (42 bytes per entity: id=4, pos=12, yaw=4, pitch=4, vel_z=4, on_ground=1, health=4, mana=4, stamina=4, team=1)
	for i in 0..<int(packet.entity_count) {
		if pos + 42 > len(buffer) {
			// Truncate if packet ends early
			packet.entity_count = u8(i)
			break
		}
		
		entity := &packet.entities[i]
		
		// Entity ID (4 bytes)
		mem.copy(&entity.id, &buffer[pos], 4); pos += 4
		
		// Position (12 bytes) - copy as a block
		mem.copy(&entity.pos, &buffer[pos], 12); pos += 12
		
		// Angles (8 bytes)
		mem.copy(&entity.yaw, &buffer[pos], 4); pos += 4
		mem.copy(&entity.pitch, &buffer[pos], 4); pos += 4
		
		// Velocity Z (4 bytes)
		mem.copy(&entity.vel_z, &buffer[pos], 4); pos += 4
		
		// Flags (1 byte)
		entity.on_ground = buffer[pos] != 0
		pos += 1
		
		// Phase 3: Resources (12 bytes)
		mem.copy(&entity.health, &buffer[pos], 4); pos += 4
		mem.copy(&entity.mana, &buffer[pos], 4); pos += 4
		mem.copy(&entity.stamina, &buffer[pos], 4); pos += 4
		
		// Phase 4: Team (1 byte)
		entity.team = Team_ID(buffer[pos]); pos += 1
	}
	
	// Phase 3: Projectile count (1 byte) - cap to 32
	if pos >= len(buffer) {
		// Old snapshot without projectiles, backward compat
		return packet, true
	}
	projectile_count_raw := buffer[pos]; pos += 1
	packet.projectile_count = min(projectile_count_raw, 32)  // Cap to array size
	
	// Phase 3: Projectile data (41 bytes each)
	for i in 0..<int(packet.projectile_count) {
		if pos + 41 > len(buffer) {
			// Truncate if packet ends early
			packet.projectile_count = u8(i)
			break
		}
		
		proj := &packet.projectiles[i]
		
		mem.copy(&proj.id, &buffer[pos], 4); pos += 4
		proj.spell_id = Spell_ID(buffer[pos]); pos += 1
		mem.copy(&proj.owner_id, &buffer[pos], 4); pos += 4
		mem.copy(&proj.pos, &buffer[pos], 12); pos += 12
		mem.copy(&proj.vel, &buffer[pos], 12); pos += 12
		mem.copy(&proj.lifetime, &buffer[pos], 4); pos += 4
		mem.copy(&proj.radius, &buffer[pos], 4); pos += 4
	}
	
	return packet, true
}

// Deserialize game state packet (Phase 4)
deserialize_server_gamestate :: proc(buffer: []u8) -> (packet: Server_GameState_Packet, ok: bool) {
	if len(buffer) < 30 {
		return {}, false
	}
	
	pos := 0
	version := buffer[pos]; pos += 1
	if version != PROTOCOL_VERSION {
		return {}, false
	}
	
	ptype := Packet_Type(buffer[pos]); pos += 1
	if ptype != .Server_GameState {
		return {}, false
	}
	
	// Match state (2 bytes)
	packet.match_state = buffer[pos]; pos += 1
	packet.match_result = buffer[pos]; pos += 1
	
	// Essence (8 bytes)
	mem.copy(&packet.alpha_essence, &buffer[pos], 4); pos += 4
	mem.copy(&packet.beta_essence, &buffer[pos], 4); pos += 4
	
	// Match time (4 bytes)
	mem.copy(&packet.match_time, &buffer[pos], 4); pos += 4
	
	// Obelisk states (3 bytes)
	for i in 0..<MAX_OBELISKS {
		packet.obelisk_states[i] = buffer[pos]; pos += 1
	}
	
	// Obelisk owners (3 bytes)
	for i in 0..<MAX_OBELISKS {
		packet.obelisk_owners[i] = buffer[pos]; pos += 1
	}
	
	// Obelisk progress (12 bytes)
	for i in 0..<MAX_OBELISKS {
		mem.copy(&packet.obelisk_progress[i], &buffer[pos], 4); pos += 4
	}
	
	return packet, true
}

// Get network stats
network_client_stats :: proc(client: ^Network_Client) -> (sent: int, recv: int, rtt_ms: f32) {
	// Simple RTT estimate (time since last receive)
	since_recv := time.tick_since(client.last_recv_time)
	rtt_est := f32(time.duration_milliseconds(since_recv))
	
	return client.packets_sent, client.packets_recv, rtt_est
}

// Enable latency simulation
network_client_sim_latency :: proc(client: ^Network_Client, latency_ms: int, loss_rate: f32) {
	client.sim_latency_ms = latency_ms
	client.sim_loss_rate = clampf(loss_rate, 0, 1)
	fmt.printf("[Client] Latency simulation: %dms, %.1f%% loss\n", latency_ms, loss_rate * 100)
}
