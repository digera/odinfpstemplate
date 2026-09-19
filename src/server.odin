package main

import "core:fmt"
import "core:time"
import "core:net"
import "core:os"
import "core:strconv"

// Headless dedicated server for Nexus Arena.
// - Fixed 60Hz deterministic tick
// - Three teams, BOTS_PER_TEAM bots each (humans join up to TEAM_SIZE)
// - Join handshake (Hello → Lobby → Join → Welcome)
// - Per-client interest-managed snapshots at 30Hz

MAX_CLIENTS   :: 16
TEAM_SIZE     :: 6          // humans per team; bots are counted separately
INPUT_QUEUE   :: 32
INPUT_BUFFER_TARGET :: 3    // inputs we like to have queued (jitter buffer)
CLIENT_TIMEOUT_SEC :: 6.0

Client_Slot :: struct {
	addr:         net.Endpoint,
	entity_id:    Entity_ID,
	team:         Team_ID,
	last_packet:  time.Tick,

	// Pending inputs sorted by tick (ascending)
	input_ticks:  [INPUT_QUEUE]u32,
	inputs:       [INPUT_QUEUE]Input_State,
	input_count:  int,
	last_applied_tick: u32,
	has_applied:  bool,
}

Server :: struct {
	world:        Entity_World,
	network:      Network_Endpoint,
	tick_id:      u32,
	running:      bool,

	tick_times_ms: [60]f32,
	tick_idx:      int,
	total_ticks:   u64,
	start_time:    time.Tick,

	clients:       [MAX_CLIENTS]Client_Slot,
	client_count:  int,

	bots:          [MAX_BOTS]Bot,
	bots_per_team: int,

	projectiles:   Projectile_World,
	lag_comp:      Lag_Comp_State,

	towers:        Tower_World,
	chunks:        Ore_Chunk_World,
	mining:        Mining_State,
	minions:       Minion_World,
	match:         Match,

	// Strikes that landed in the last STRIKE_LINGER_SEC, replayed into every
	// snapshot until they age out so a lost packet does not lose the bolt.
	strikes:       [MAX_STRIKES]Strike,
	strike_seq:    u8,
}

MAX_STRIKES       :: 16
STRIKE_LINGER_SEC :: f32(0.35) // ~10 snapshots

Strike :: struct {
	live:     bool,
	seq:      u8,
	owner_id: Entity_ID,
	pos:      vec3,
	age:      f32,
}

// Initializes in place rather than returning a Server. It has to: the pylon
// world registers itself in a global so collision queries can reach it, and a
// Server that moved after that -- as a by-value return does -- would leave that
// pointer aimed at a dead frame.
server_init :: proc(server: ^Server, port: u16) -> bool {
	fmt.println("=== Nexus Arena Headless Server ===")

	server^ = {}
	server.world = entity_world_init()
	server.start_time = time.tick_now()
	server.projectiles = projectile_world_init()
	server.lag_comp = lag_comp_init()
	// Towers must exist before anything asks the world whether a point is free:
	// they are part of the collision set now.
	tower_world_init(&server.towers)
	ore_chunk_world_init(&server.chunks)
	minion_world_init(&server.minions)
	server.match = match_init()

	server.bots_per_team = BOTS_PER_TEAM
	{
		buf: [64]u8
		if v := os.get_env_buf(buf[:], "BOTS_PER_TEAM"); v != "" {
			if count, pok := strconv.parse_int(v); pok && count >= 0 && count <= TEAM_SIZE {
				server.bots_per_team = count
				fmt.printf("Bot count override: %d bots per team\n", count)
			}
		}
	}

	fmt.printf("Initializing on port %d, %d teams x %d human slots, %d bots per team\n",
		port, TEAM_COUNT, TEAM_SIZE, server.bots_per_team)

	// Test knobs: NEXUS_TEST_ESSENCE=50 (win threshold), NEXUS_TEST_FAST=10 (essence multiplier)
	{
		buf: [64]u8
		if v := os.get_env_buf(buf[:], "NEXUS_TEST_ESSENCE"); v != "" {
			if threshold, pok := strconv.parse_f32(v); pok && threshold > 0 {
				match_configure_test_mode(threshold, test_essence_multiplier)
			}
		}
	}
	{
		buf: [64]u8
		if v := os.get_env_buf(buf[:], "NEXUS_TEST_FAST"); v != "" {
			if mult, pok := strconv.parse_f32(v); pok && mult > 0 {
				match_configure_test_mode(test_essence_threshold, mult)
			}
		}
	}

	if port > 0 {
		if !network_init(&server.network, port) {
			fmt.eprintln("Warning: network init failed, running offline")
		}
	}

	bots_rebalance(server)

	fmt.printf("Server ready: %d entities active\n", server.world.count)
	server.running = true
	return true
}

// ---------------------------------------------------------------------------
// Tick

server_tick :: proc(server: ^Server) {
	tick_start := time.tick_now()

	server_process_packets(server)
	server_check_timeouts(server)
	server_apply_client_inputs(server)

	bots_tick(server, SIMULATION_DT)

	server_update_resources(server, SIMULATION_DT)
	entity_tick_death_respawn(&server.world, SIMULATION_DT)

	simulate_world_step(&server.world)
	projectile_tick(&server.projectiles, &server.world, SIMULATION_DT)
	beams_tick(&server.world, SIMULATION_DT, server.match.state != .Ended)
	server_age_strikes(server, SIMULATION_DT)
	combat_log_tick(&server.world.combat_log, SIMULATION_DT)

	// Mining comes after the beams so a beam that went out this tick gets no
	// free bite, and before the structure check so a bite that severs a slab is
	// resolved in the same tick the player made it.
	live := server.match.state != .Ended
	mining_beams_tick(&server.mining, &server.towers, &server.chunks, &server.world, SIMULATION_DT, live)
	tower_world_tick(&server.towers, &server.chunks, SIMULATION_DT)
	ore_chunk_tick(&server.chunks, SIMULATION_DT)
	if live {
		mining_harvest_tick(&server.chunks, &server.world, &server.match)
	}

	// The waves run after mining, so ore banked this tick is in the wallet the
	// next wave reads, and before the match check, so a donation that finishes
	// the centre wins the round on the tick it lands.
	minions_tick(&server.minions, &server.world, &server.towers, &server.chunks, &server.match, SIMULATION_DT, live)
	match_centre_tick(&server.match, &server.towers)

	if match_tick(&server.match, SIMULATION_DT) {
		server_round_reset(server)
	}

	for i in 1..<MAX_ENTITIES {
		if server.world.characters[i].active {
			lag_comp_record(&server.lag_comp, Entity_ID(i), server.world.characters[i].pos, server.tick_id)
		}
	}

	if server.tick_id % 2 == 0 {
		server_send_snapshots(server)
	}
	if server.tick_id % 6 == 0 {
		server_send_gamestate(server)
	}
	if server.tick_id % 30 == 0 {
		server_send_roster(server)
	}

	server.tick_id += 1
	server.total_ticks += 1

	tick_ms := f32(time.duration_milliseconds(time.tick_since(tick_start)))
	server.tick_times_ms[server.tick_idx] = tick_ms
	server.tick_idx = (server.tick_idx + 1) % len(server.tick_times_ms)
}

server_round_reset :: proc(server: ^Server) {
	tower_world_reset(&server.towers)
	ore_chunk_world_reset(&server.chunks)
	mining_reset(&server.mining)
	minion_world_reset(&server.minions)
	projectile_clear_all(&server.projectiles)
	server.strikes = {}
	combat_reset_stats(&server.world)
	entity_respawn_all(&server.world)
	for i in 0..<MAX_BOTS {
		if server.bots[i].active {
			bot_reset_ai(&server.bots[i])
		}
	}
	fmt.println("[Server] Round reset: pylons raised, ore cleared, everyone respawned")
}

// ---------------------------------------------------------------------------
// Packets

server_process_packets :: proc(server: ^Server) {
	buffer: [MAX_PACKET_SIZE]u8

	for _ in 0..<200 {
		n, from, ok := network_receive(&server.network, buffer[:])
		if !ok {
			break
		}
		ptype, hdr_ok := packet_header(buffer[:n])
		if !hdr_ok {
			continue
		}

		slot := server_find_client(server, from)

		#partial switch ptype {
		case .Client_Hello:
			if slot >= 0 {
				server.clients[slot].last_packet = time.tick_now()
				server_send_welcome(server, slot)
			} else {
				server_send_lobby(server, from, .None)
			}

		case .Client_Join:
			join, jok := deserialize_client_join(buffer[:n])
			if !jok {
				continue
			}
			if slot >= 0 {
				// Already in: handle team switch
				client := &server.clients[slot]
				if client.team != join.team {
					reject := server_validate_join(server, join.team, true)
					if reject != .None {
						server_send_lobby(server, from, reject)
						continue
					}
					if !server_apply_team_switch(server, client, join.team, join.name) {
						server_send_lobby(server, from, .Server_Full)
						continue
					}
					fmt.printf("[Server] Client %v switched to %s", from, team_name(join.team))
					if client.entity_id != INVALID_ENTITY {
						fmt.printf(" as entity %d\n", client.entity_id)
					} else {
						fmt.printf("\n")
					}
				}
				client.last_packet = time.tick_now()
				server_send_welcome(server, slot)
				continue
			}
			reject := server_validate_join(server, join.team)
			if reject != .None {
				server_send_lobby(server, from, reject)
				continue
			}
			new_slot := server_register_client(server, from, join.team, join.name)
			if new_slot >= 0 {
				server_send_welcome(server, new_slot)
				server_send_gamestate_to(server, new_slot)
				// Don't make them wait half a second to learn who is here.
				server_send_roster_to(server, new_slot)
			} else {
				server_send_lobby(server, from, .Server_Full)
			}

		case .Client_Input:
			if slot < 0 {
				continue // unknown endpoint; it must Join first
			}
			pkt, pok := deserialize_client_input(buffer[:n])
			if !pok {
				continue
			}
			client := &server.clients[slot]
			client.last_packet = time.tick_now()
			for k in 0..<int(pkt.count) {
				tick := pkt.newest_tick - u32(k)
				client_queue_input(client, tick, pkt.inputs[k])
			}
		}
	}
}

server_find_client :: proc(server: ^Server, addr: net.Endpoint) -> int {
	for i in 0..<server.client_count {
		c := &server.clients[i]
		if c.addr.address == addr.address && c.addr.port == addr.port {
			return i
		}
	}
	return -1
}

// Insert an input into a client's sorted pending queue (dedup by tick).
client_queue_input :: proc(client: ^Client_Slot, tick: u32, input: Input_State) {
	if client.has_applied && tick <= client.last_applied_tick {
		return
	}
	for i in 0..<client.input_count {
		if client.input_ticks[i] == tick {
			return
		}
	}
	if client.input_count >= INPUT_QUEUE {
		// Drop the oldest
		for i in 0..<INPUT_QUEUE - 1 {
			client.input_ticks[i] = client.input_ticks[i + 1]
			client.inputs[i] = client.inputs[i + 1]
		}
		client.input_count -= 1
	}
	// Sorted insert
	pos := client.input_count
	for pos > 0 && client.input_ticks[pos - 1] > tick {
		client.input_ticks[pos] = client.input_ticks[pos - 1]
		client.inputs[pos] = client.inputs[pos - 1]
		pos -= 1
	}
	client.input_ticks[pos] = tick
	client.inputs[pos] = input
	client.input_count += 1
}

// Consume one queued input per client per tick. If the buffer runs long,
// skip ahead (keeping any cast intent); if it runs dry, repeat the last input.
server_apply_client_inputs :: proc(server: ^Server) {
	for i in 0..<server.client_count {
		client := &server.clients[i]
		id := client.entity_id
		if id == INVALID_ENTITY {
			continue
		}

		if client.input_count == 0 {
			server.world.inputs[id].cast_spell = .None
			continue
		}

		// Catch up if we've accumulated too much. Skipped inputs still feed the
		// channel so a burst of packets can't rob a player of their wind-up.
		for client.input_count > INPUT_BUFFER_TARGET + 2 {
			server_advance_channel(server, id, client.inputs[0])
			client_pop_input(client)
		}

		input := client.inputs[0]
		tick := client.input_ticks[0]
		client_pop_input(client)
		client.last_applied_tick = tick
		client.has_applied = true

		server.world.inputs[id] = input
		server_advance_channel(server, id, input)
	}
}

// Fold one input tick into the caster's wind-up. The client reports which
// spell it is winding and when it wants to fire; the server times the charge
// and will not release until the wind-up is full, so a client can never claim
// a hold it never did or fire a half-charged shot. An early `cast_spell` is a
// commit: the channel keeps going and fires itself once it is full.
@(private = "file")
server_advance_channel :: proc(server: ^Server, id: Entity_ID, input: Input_State) {
	spell_state := &server.world.spell_states[id]

	if !entity_alive(&server.world, id) {
		spell_state.channel_spell = .None
		spell_state.channel_time = 0
		spell_state.channel_committed = false
		return
	}

	if input.cast_spell != .None {
		if spell_state.channel_spell == input.cast_spell {
			def := &SPELL_DEFS[input.cast_spell]
			if spell_charge_frac(def, spell_state.channel_time) >= 1 {
				server_fire_channel(server, id, input)
				return
			}
			// Released before the bar filled: keep winding, fire at full.
			spell_state.channel_committed = true
		} else {
			return
		}
	}

	// Swapping spells restarts the wind-up. Letting go of a charge-cast that
	// has not been committed drops it; a committed one keeps going with no
	// charge_spell on the wire.
	if input.charge_spell != spell_state.channel_spell {
		if spell_state.channel_committed && input.charge_spell == .None {
			// Keep the committed wind-up.
		} else {
			spell_state.channel_committed = false
			if SPELL_DEFS[input.charge_spell].payload == .Beam {
				// Refused, a beam stays dark while the button is held and relights
				// the tick it becomes castable, the way a held wind-up restarts
				// after its cooldown.
				beam_quench(&server.world, id)
				if server.match.state != .Ended {
					beam_light(&server.world, id, input.charge_spell)
				}
			} else {
				spell_state.channel_spell = input.charge_spell
				spell_state.channel_time = 0
				spell_state.beam = {}
			}
		}
	}
	if spell_state.channel_spell != .None {
		def := &SPELL_DEFS[spell_state.channel_spell]
		spell_state.channel_time = min(spell_state.channel_time + FIXED_DT, def.cast_time)
		if spell_state.channel_committed && def.payload != .Beam &&
		   spell_charge_frac(def, spell_state.channel_time) >= 1 {
			server_fire_channel(server, id, input)
		}
	}
}

@(private = "file")
server_fire_channel :: proc(server: ^Server, id: Entity_ID, input: Input_State) {
	spell_state := &server.world.spell_states[id]
	spell := spell_state.channel_spell
	spell_state.channel_spell = .None
	spell_state.channel_time = 0
	spell_state.channel_committed = false
	if spell != .None {
		server_handle_spell_cast(server, id, spell, 1.0, server.tick_id, input.target_id)
	}
}

@(private = "file")
client_pop_input :: proc(client: ^Client_Slot) {
	if client.input_count == 0 {
		return
	}
	for i in 0..<client.input_count - 1 {
		client.input_ticks[i] = client.input_ticks[i + 1]
		client.inputs[i] = client.inputs[i + 1]
	}
	client.input_count -= 1
}

server_check_timeouts :: proc(server: ^Server) {
	for i := 0; i < server.client_count; {
		elapsed := time.duration_seconds(time.tick_since(server.clients[i].last_packet))
		if elapsed > CLIENT_TIMEOUT_SEC {
			fmt.printf("[Server] Client %v timed out (%.1fs), removing entity %d\n",
				server.clients[i].addr, elapsed, server.clients[i].entity_id)
			server_remove_client(server, i)
		} else {
			i += 1
		}
	}
}

server_remove_client :: proc(server: ^Server, idx: int) {
	entity_destroy(&server.world, server.clients[idx].entity_id)
	last := server.client_count - 1
	if idx != last {
		server.clients[idx] = server.clients[last]
	}
	server.clients[last] = {}
	server.client_count -= 1
	bots_rebalance(server)
}

// ---------------------------------------------------------------------------
// Join flow

server_human_counts :: proc(server: ^Server) -> [TEAM_COUNT]int {
	counts: [TEAM_COUNT]int
	for i in 0..<server.client_count {
		idx := team_index(server.clients[i].team)
		if idx >= 0 {
			counts[idx] += 1
		}
	}
	return counts
}

server_validate_join :: proc(server: ^Server, team: Team_ID, already_connected := false) -> Lobby_Reject {
	if !already_connected && server.client_count >= MAX_CLIENTS {
		return .Server_Full
	}
	if team == .Spectator {
		return .None
	}
	idx := team_index(team)
	if idx < 0 {
		return .Invalid_Team
	}
	counts := server_human_counts(server)
	if counts[idx] >= TEAM_SIZE {
		return .Team_Most_Populated
	}
	if !team_join_allowed(counts, team) {
		return .Team_Most_Populated
	}
	return .None
}

// The name a client asked for, or one we make up. `br_name` has already
// stripped anything unprintable, so what is left to decide is whether there is
// a name at all: a player who typed only spaces gets Player-NN like everyone
// who typed nothing.
@(private = "file")
server_resolve_name :: proc(requested: Player_Name, id: Entity_ID) -> Player_Name {
	out := requested
	for out.len > 0 && out.text[out.len - 1] == ' ' {
		out.len -= 1
	}
	if out.len == 0 {
		player_name_set(&out, fmt.tprintf("Player-%02d", id))
	}
	return out
}

// Move an already-connected client onto another team (or spectator).
// Counts the destination before the team field changes so spawn slots stay
// correct, and copies the name onto the new body.
@(private = "file")
server_apply_team_switch :: proc(server: ^Server, client: ^Client_Slot, team: Team_ID, requested_name: Player_Name) -> bool {
	name := requested_name
	if client.entity_id != INVALID_ENTITY {
		if name.len == 0 {
			name = server.world.names[client.entity_id]
		}
		entity_destroy(&server.world, client.entity_id)
		client.entity_id = INVALID_ENTITY
	}

	if team == .Spectator {
		client.team = .Spectator
		bots_rebalance(server)
		return true
	}

	counts := server_human_counts(server)
	spawn_slot := counts[team_index(team)]
	spawn_pos := team_spawn_position(team, spawn_slot)
	yaw := wrap_angle(team_angle(team) + 3.14159265)
	new_id := entity_spawn(&server.world, spawn_pos, team, yaw)
	if new_id == INVALID_ENTITY {
		fmt.eprintln("[Server] Failed to spawn player entity on team switch")
		return false
	}
	client.entity_id = new_id
	client.team = team
	server.world.names[new_id] = server_resolve_name(name, new_id)
	bots_rebalance(server)
	return true
}

server_register_client :: proc(server: ^Server, addr: net.Endpoint, team: Team_ID, requested_name: Player_Name) -> int {
	if server.client_count >= MAX_CLIENTS {
		return -1
	}

	player_id: Entity_ID = INVALID_ENTITY

	// Spectators don't get an entity, and must not write names[INVALID_ENTITY].
	if team != .Spectator {
		counts := server_human_counts(server)
		spawn_slot := counts[team_index(team)]
		spawn_pos := team_spawn_position(team, spawn_slot)
		yaw := wrap_angle(team_angle(team) + 3.14159265)

		player_id = entity_spawn(&server.world, spawn_pos, team, yaw)
		if player_id == INVALID_ENTITY {
			fmt.eprintln("[Server] Failed to spawn player entity")
			return -1
		}
		server.world.names[player_id] = server_resolve_name(requested_name, player_id)
	}

	idx := server.client_count
	server.clients[idx] = Client_Slot{
		addr        = addr,
		entity_id   = player_id,
		team        = team,
		last_packet = time.tick_now(),
	}
	server.client_count += 1

	if team == .Spectator {
		fmt.printf("[Server] Client %v joined as spectator (%d clients)\n",
			addr, server.client_count)
	} else {
		fmt.printf("[Server] Client %v joined %s as '%s' (entity %d, %d clients)\n",
			addr, team_name(team), player_name_display(&server.world.names[player_id], player_id, false),
			player_id, server.client_count)
	}

	bots_rebalance(server)
	return idx
}

server_send_lobby :: proc(server: ^Server, to: net.Endpoint, reject: Lobby_Reject) {
	humans := server_human_counts(server)
	bots := bots_count_per_team(server)
	packet := Server_Lobby_Packet{team_size = TEAM_SIZE, reject = reject}
	for i in 0..<TEAM_COUNT {
		packet.humans[i] = u8(humans[i])
		packet.bots[i] = u8(bots[i])
	}
	buffer: [32]u8
	size := serialize_server_lobby(&packet, buffer[:])
	network_send(&server.network, buffer[:], size, to)
}

server_send_welcome :: proc(server: ^Server, slot: int) {
	client := &server.clients[slot]
	welcome := Server_Welcome_Packet{your_entity_id = client.entity_id, team = client.team}
	buffer: [16]u8
	size := serialize_server_welcome(&welcome, buffer[:])
	network_send(&server.network, buffer[:], size, client.addr)
}

// ---------------------------------------------------------------------------
// Snapshots (per client, nearest entities first, self always included)

server_send_snapshots :: proc(server: ^Server) {
	if server.client_count == 0 {
		return
	}
	buffer: [MAX_PACKET_SIZE]u8

	// Bots and humans share the entity array; clients only need the distinction
	// to label a target.
	bot_ids: [MAX_ENTITIES]bool
	for i in 0..<MAX_BOTS {
		b := &server.bots[i]
		if b.active && b.id < MAX_ENTITIES {
			bot_ids[b.id] = true
		}
	}

	dirty: [MAX_SNAPSHOT_OCC_PYLONS]Pylon_ID
	dirty_n := tower_collect_dirty(&server.towers, dirty[:])

	for ci in 0..<server.client_count {
		client := &server.clients[ci]
		self_id := client.entity_id
		self_pos: vec3
		if self_id == INVALID_ENTITY {
			// Spectators have no body; interest-manage from the plaza.
			self_pos = {}
		} else {
			self_pos = server.world.characters[self_id].pos
		}

		snapshot := Server_Snapshot_Packet{
			tick_id        = server.tick_id,
			ack_input_tick = client.has_applied ? client.last_applied_tick : 0,
		}

		// Gather (dist², id) for active entities
		cand_ids:  [MAX_ENTITIES]Entity_ID
		cand_dist: [MAX_ENTITIES]f32
		cand_n := 0
		for i in 1..<MAX_ENTITIES {
			if !server.world.characters[i].active {
				continue
			}
			d := server.world.characters[i].pos - self_pos
			cand_ids[cand_n] = Entity_ID(i)
			cand_dist[cand_n] = Entity_ID(i) == self_id ? -1 : len2_vec3(d)
			cand_n += 1
		}
		// Partial selection of the nearest MAX_SNAPSHOT_ENTITIES
		take := min(cand_n, MAX_SNAPSHOT_ENTITIES)
		for k in 0..<take {
			best := k
			for j in k + 1..<cand_n {
				if cand_dist[j] < cand_dist[best] {
					best = j
				}
			}
			if best != k {
				cand_ids[k], cand_ids[best] = cand_ids[best], cand_ids[k]
				cand_dist[k], cand_dist[best] = cand_dist[best], cand_dist[k]
			}
			id := cand_ids[k]
			char := server.world.characters[id]
			// The wind-up in this entity's hand, for the cast orb the client
			// draws on it. Timed here like the cast itself, so a telegraph is
			// as authoritative as the spell it warns about. Spells with no
			// cast time -- the beams -- come back at full: they are either lit
			// or they are not.
			spell_state := &server.world.spell_states[id]
			channel_frac: f32 = 0
			if spell_state.channel_spell != .None {
				channel_frac = spell_charge_frac(&SPELL_DEFS[spell_state.channel_spell], spell_state.channel_time)
			}
			snapshot.entities[k] = Snapshot_Entity{
				id            = id,
				pos           = char.pos,
				vel           = char.vel,
				yaw           = char.yaw,
				pitch         = char.pitch,
				on_ground     = char.on_ground,
				dead          = char.dead,
				is_bot        = bot_ids[id],
				health        = char.health,
				mana          = char.mana,
				stamina       = char.stamina,
				team          = server.world.teams[id],
				slow_ticks    = char.slow_ticks,
				channel_spell = spell_state.channel_spell,
				channel_frac  = channel_frac,
			}
		}
		snapshot.entity_count = u8(take)

		// Nearest minions, selected the same way. A wave the client cannot see
		// is a wave it does not need: the ones that matter are the fourteen
		// bodies in the lane you are standing in, and a fight at the far pylon
		// can have its own fourteen.
		midx:  [MAX_MINIONS]int
		mdist: [MAX_MINIONS]f32
		mn := 0
		for i in 0..<MAX_MINIONS {
			if !server.minions.minions[i].active {
				continue
			}
			midx[mn] = i
			mdist[mn] = len2_vec3(server.minions.minions[i].pos - self_pos)
			mn += 1
		}
		mtake := min(mn, MAX_SNAPSHOT_MINIONS)
		for k in 0..<mtake {
			best := k
			for j in k + 1..<mn {
				if mdist[j] < mdist[best] {
					best = j
				}
			}
			if best != k {
				midx[k], midx[best] = midx[best], midx[k]
				mdist[k], mdist[best] = mdist[best], mdist[k]
			}
			m := &server.minions.minions[midx[k]]
			snapshot.minions[k] = Snapshot_Minion{
				id   = m.id,
				kind = m.kind,
				team = m.team,
				pos  = m.pos,
				yaw  = m.yaw,
				hp   = m.health_max > 0 ? clampf(m.health / m.health_max, 0, 1) : 0,
			}
		}
		snapshot.minion_count = u8(mtake)

		// Nearest projectiles
		pidx:  [MAX_PROJECTILES]int
		pdist: [MAX_PROJECTILES]f32
		pn := 0
		for i in 0..<MAX_PROJECTILES {
			if !server.projectiles.projectiles[i].active {
				continue
			}
			pidx[pn] = i
			pdist[pn] = len2_vec3(server.projectiles.projectiles[i].pos - self_pos)
			pn += 1
		}
		ptake := min(pn, MAX_SNAPSHOT_PROJECTILES)
		for k in 0..<ptake {
			best := k
			for j in k + 1..<pn {
				if pdist[j] < pdist[best] {
					best = j
				}
			}
			if best != k {
				pidx[k], pidx[best] = pidx[best], pidx[k]
				pdist[k], pdist[best] = pdist[best], pdist[k]
			}
			proj := server.projectiles.projectiles[pidx[k]]
			snapshot.projectiles[k] = Snapshot_Projectile{
				id       = proj.id,
				spell_id = proj.spell_id,
				owner_id = proj.owner_id,
				pos      = proj.pos,
				vel      = proj.vel,
				lifetime = proj.lifetime,
				radius   = proj.radius,
			}
		}
		snapshot.projectile_count = u8(ptake)

		// Recent strikes, nearest first. A bolt is visible from across the
		// arena, so this only matters when more than four land at once.
		sidx:  [MAX_STRIKES]int
		sdist: [MAX_STRIKES]f32
		sn := 0
		for i in 0..<MAX_STRIKES {
			if !server.strikes[i].live {
				continue
			}
			sidx[sn] = i
			sdist[sn] = len2_vec3(server.strikes[i].pos - self_pos)
			sn += 1
		}
		stake := min(sn, MAX_SNAPSHOT_STRIKES)
		for k in 0..<stake {
			best := k
			for j in k + 1..<sn {
				if sdist[j] < sdist[best] {
					best = j
				}
			}
			if best != k {
				sidx[k], sidx[best] = sidx[best], sidx[k]
				sdist[k], sdist[best] = sdist[best], sdist[k]
			}
			strike := &server.strikes[sidx[k]]
			snapshot.strikes[k] = Snapshot_Strike{seq = strike.seq, owner_id = strike.owner_id, pos = strike.pos}
		}
		snapshot.strike_count = u8(stake)

		// Lit beams, nearest owner first. The client's own beam always goes:
		// it is what tells them the server agrees they are firing.
		bidx:  [MAX_ENTITIES]int
		bdist: [MAX_ENTITIES]f32
		bn := 0
		for i in 1..<MAX_ENTITIES {
			if !spell_state_beaming(&server.world.spell_states[i]) || !entity_alive(&server.world, Entity_ID(i)) {
				continue
			}
			bidx[bn] = i
			bdist[bn] = Entity_ID(i) == self_id ? -1 : len2_vec3(server.world.characters[i].pos - self_pos)
			bn += 1
		}
		btake := min(bn, MAX_SNAPSHOT_BEAMS)
		for k in 0..<btake {
			best := k
			for j in k + 1..<bn {
				if bdist[j] < bdist[best] {
					best = j
				}
			}
			if best != k {
				bidx[k], bidx[best] = bidx[best], bidx[k]
				bdist[k], bdist[best] = bdist[best], bdist[k]
			}
			spell_state := &server.world.spell_states[bidx[k]]
			beam := &spell_state.beam
			snapshot.beams[k] = Snapshot_Beam{
				owner_id    = Entity_ID(bidx[k]),
				spell_id    = spell_state.channel_spell,
				end         = beam.end,
				hit         = beam.hit != INVALID_ENTITY || beam.hit_minion,
				chain_count = u8(beam.chain_count),
				chains      = beam.chains,
				chain_minion_ids = beam.chain_minion_ids,
			}
		}
		snapshot.beam_count = u8(btake)

		// This client's own combat log and nobody else's.
		snapshot.combat_event_count = u8(combat_log_gather(&server.world.combat_log, self_id, &snapshot.combat_events))

		snapshot.tower_count = u8(dirty_n)
		for k in 0..<dirty_n {
			id := dirty[k]
			t := tower_get(&server.towers, id)
			snapshot.towers[k].tower_id = id
			if t != nil {
				tower_pack_nodes(t, snapshot.towers[k].node_hp[:])
			}
		}

		// Nearest ore on the floor.
		kidx:  [MAX_ORE_CHUNKS]int
		kdist: [MAX_ORE_CHUNKS]f32
		kn := 0
		for i in 0..<MAX_ORE_CHUNKS {
			if !server.chunks.chunks[i].active {
				continue
			}
			kidx[kn] = i
			kdist[kn] = len2_vec3(server.chunks.chunks[i].pos - self_pos)
			kn += 1
		}
		ktake := min(kn, MAX_SNAPSHOT_CHUNKS)
		for k in 0..<ktake {
			best := k
			for j in k + 1..<kn {
				if kdist[j] < kdist[best] {
					best = j
				}
			}
			if best != k {
				kidx[k], kidx[best] = kidx[best], kidx[k]
				kdist[k], kdist[best] = kdist[best], kdist[k]
			}
			c := &server.chunks.chunks[kidx[k]]
			snapshot.chunks[k] = Snapshot_Chunk{
				id     = c.id,
				ore    = c.ore,
				pos    = c.pos,
				vel    = c.vel,
				radius = c.radius,
				rest   = c.rest,
			}
		}
		snapshot.chunk_count = u8(ktake)

		size := serialize_server_snapshot(&snapshot, buffer[:])
		if size > 0 {
			network_send(&server.network, buffer[:], size, client.addr)
		}
	}
	tower_clear_dirty(&server.towers, dirty[:dirty_n])
}

// ---------------------------------------------------------------------------
// Roster (everyone in the match, 2Hz)
//
// Unlike a snapshot this is not interest-managed. A scoreboard that only knew
// about the players you happened to be standing near would be worse than no
// scoreboard, and the name over a target has to survive them stepping out of
// your nearest-21 for a moment.

#assert(MAX_CLIENTS + MAX_BOTS <= MAX_ROSTER_ENTRIES)

server_build_roster :: proc(server: ^Server) -> Server_Roster_Packet {
	bot_ids: [MAX_ENTITIES]bool
	for i in 0..<MAX_BOTS {
		b := &server.bots[i]
		if b.active && b.id < MAX_ENTITIES {
			bot_ids[b.id] = true
		}
	}

	packet: Server_Roster_Packet
	count := 0
	for i in 1..<MAX_ENTITIES {
		if !server.world.characters[i].active || count >= MAX_ROSTER_ENTRIES {
			continue
		}
		id := Entity_ID(i)
		packet.entries[count] = Roster_Entry{
			id     = id,
			team   = server.world.teams[i],
			is_bot = bot_ids[i],
			name   = server.world.names[i],
			stats  = server.world.stats[i],
		}
		count += 1
	}
	packet.count = u8(count)
	return packet
}

server_send_roster :: proc(server: ^Server) {
	if server.client_count == 0 {
		return
	}
	roster := server_build_roster(server)
	buffer: [MAX_PACKET_SIZE]u8
	size := serialize_server_roster(&roster, buffer[:])
	if size <= 0 {
		return
	}
	for i in 0..<server.client_count {
		network_send(&server.network, buffer[:], size, server.clients[i].addr)
	}
}

server_send_roster_to :: proc(server: ^Server, slot: int) {
	roster := server_build_roster(server)
	buffer: [MAX_PACKET_SIZE]u8
	size := serialize_server_roster(&roster, buffer[:])
	if size > 0 {
		network_send(&server.network, buffer[:], size, server.clients[slot].addr)
	}
}

server_build_gamestate :: proc(server: ^Server) -> Server_GameState_Packet {
	gs := Server_GameState_Packet{
		match_state  = u8(server.match.state),
		match_result = u8(server.match.result),
		winner       = u8(server.match.winner),
		essence      = server.match.essence,
		centre_open  = server.match.centre_open,
		match_time   = server.match.match_time,
	}
	// Shares, not voxel counts: the HUD wants "who is winning the centre", and
	// a percentage survives the one byte it gets on the wire.
	{
		total: f32
		for i in 0..<TEAM_COUNT {
			total += server.match.centre_build[i]
		}
		if total > 0 {
			for i in 0..<TEAM_COUNT {
				gs.centre_share[i] = quant_u8(server.match.centre_build[i] / total, 255)
			}
		}
	}
	humans := server_human_counts(server)
	for i in 0..<TEAM_COUNT {
		gs.humans[i] = u8(humans[i])
		for k in 0..<ORE_COUNT {
			gs.wallets[i][k] = u16(clampf(server.match.wallets[i][k], 0, 65535))
		}
	}
	for i in 0..<MAX_PYLONS {
		t := &server.towers.towers[i]
		gs.towers[i].intact = t.intact
		tower_pack_nodes(t, gs.towers[i].node_hp[:])
	}
	return gs
}

server_send_gamestate :: proc(server: ^Server) {
	if server.client_count == 0 {
		return
	}
	gs := server_build_gamestate(server)
	buffer: [MAX_PACKET_SIZE]u8
	size := serialize_server_gamestate(&gs, buffer[:])
	if size <= 0 {
		return
	}
	for i in 0..<server.client_count {
		network_send(&server.network, buffer[:], size, server.clients[i].addr)
	}
}

server_send_gamestate_to :: proc(server: ^Server, slot: int) {
	gs := server_build_gamestate(server)
	buffer: [MAX_PACKET_SIZE]u8
	size := serialize_server_gamestate(&gs, buffer[:])
	if size > 0 {
		network_send(&server.network, buffer[:], size, server.clients[slot].addr)
	}
}

// ---------------------------------------------------------------------------
// Resources & spells

server_update_resources :: proc(server: ^Server, dt: f32) {
	for i in 1..<MAX_ENTITIES {
		if !server.world.characters[i].active {
			continue
		}
		char := &server.world.characters[i]
		spell_state := &server.world.spell_states[i]

		if !char.dead {
			char.mana = min(char.mana + MANA_REGEN_PER_SEC * dt, MANA_MAX)
		}
		for spell_id in Spell_ID {
			if spell_state.cooldowns[spell_id] > 0 {
				spell_state.cooldowns[spell_id] = max(spell_state.cooldowns[spell_id] - dt, 0)
			}
		}
	}
}

// Validate and execute a spell cast at the given charge. `target_id` is what
// the caster's crosshair was holding; only targeted spells read it, and they
// re-check it here before anything is spent. Returns true if the cast happened.
server_handle_spell_cast :: proc(server: ^Server, caster_id: Entity_ID, spell_id: Spell_ID, charge_frac: f32, tick: u32, target_id := INVALID_ENTITY) -> bool {
	if !entity_alive(&server.world, caster_id) {
		return false
	}
	if !spell_valid(spell_id) {
		return false
	}
	if server.match.state == .Ended {
		return false
	}

	def := &SPELL_DEFS[spell_id]
	// A beam did its work while it was held; letting go is not a cast.
	if def.payload == .Beam {
		return false
	}
	spell_state := &server.world.spell_states[caster_id]
	char := server.world.characters[caster_id]
	if !spell_castable(spell_id, char, spell_state.cooldowns[spell_id]) {
		return false
	}

	origin := vec3{char.pos.x, char.pos.y, char.pos.z + PLAYER_EYE_M}
	direction := camera_forward(char.yaw, char.pitch)

	// A strike with nowhere to land is refused, not refunded: the wind-up was
	// the price of letting the target slip behind cover.
	if def.payload == .Strike && !server_strike_target_ok(server, caster_id, target_id, def, origin, direction) {
		return false
	}
	// A heal with nobody missing health is the same: refused before the mana
	// is spent, whether that is the caster, a reachable ally, or both.
	if def.payload == .Heal && !server_heal_does_work(server, caster_id, target_id, def, origin, direction) {
		return false
	}

	charge := clampf(charge_frac, SPELL_MIN_CHARGE, 1)

	char.mana -= def.mana_cost
	spell_state.cooldowns[spell_id] = def.cooldown_sec

	switch def.payload {
	case .Projectile:
		spell_cast := Spell_Cast{
			caster_id   = caster_id,
			spell_id    = spell_id,
			origin      = origin,
			direction   = direction,
			tick        = tick,
			charge_frac = charge,
		}
		projectile_spawn(&server.projectiles, &server.world, &spell_cast, def)

	case .Teleport:
		blink_dir := norm_vec3(vec3{direction.x, direction.y, 0})
		if len2_vec3(blink_dir) < 0.5 {
			blink_dir = camera_forward(char.yaw, 0)
		}
		// Walk the blink forward in small steps and stop at the last free spot.
		reach := def.range * charge
		best := char.pos
		steps := 24
		for s in 1..=steps {
			cand := char.pos + blink_dir * (reach * f32(s) / f32(steps))
			if blink_spot_free(cand) {
				best = cand
			} else {
				break
			}
		}
		char.pos = best
		char.vel.x = blink_dir.x * 3.0
		char.vel.y = blink_dir.y * 3.0

	case .Strike:
		// Touches the target and bystanders only; the splash skips its owner,
		// so the caster copy written back below stays authoritative.
		server_strike(server, caster_id, target_id, def, charge)

	case .Heal:
		amount := spell_heal_amount(def, charge)
		self_got := character_mend(&char, amount)
		ally_got: f32 = 0
		if server_heal_ally_ok(server, caster_id, target_id, def, origin, direction) {
			ally := server.world.characters[target_id]
			ally_got = character_mend(&ally, amount)
			server.world.characters[target_id] = ally
		}
		if SERVER_VERBOSE {
			if ally_got > 0 {
				server_log("[Combat] %s mended %d for %.0f and %d for %.0f (%.0f HP)",
					def.short_name, caster_id, self_got, target_id, ally_got, char.health)
			} else {
				server_log("[Combat] %s mended %d for %.0f (%.0f HP)",
					def.short_name, caster_id, self_got, char.health)
			}
		}

	case .Beam: // refused above
	case .None:
	}

	server.world.characters[caster_id] = char

	if SERVER_VERBOSE {
		server_log("[Combat] Entity %d cast %s at %.0f%% charge", caster_id, def.name, charge * 100)
	}
	return true
}

// Everything the server demands of a strike target: alive, hostile, and
// within the shared reach test from the caster's real eye and look.
@(private = "file")
server_strike_target_ok :: proc(server: ^Server, caster_id, target_id: Entity_ID, def: ^Spell_Def, eye, look: vec3) -> bool {
	if target_id == caster_id || !entity_alive(&server.world, target_id) {
		return false
	}
	if !teams_are_enemies(server.world.teams[caster_id], server.world.teams[target_id]) {
		return false
	}
	return strike_target_in_reach(def, eye, look, server.world.characters[target_id].pos)
}

// A heal is worth firing if the caster is missing health, or a reachable ally
// is. Full bars on everyone is a refuse, not a spend.
@(private = "file")
server_heal_does_work :: proc(server: ^Server, caster_id, target_id: Entity_ID, def: ^Spell_Def, eye, look: vec3) -> bool {
	if server.world.characters[caster_id].health < HEALTH_MAX {
		return true
	}
	return server_heal_ally_ok(server, caster_id, target_id, def, eye, look)
}

// Everything the server demands of a heal's ally: alive, friendly, missing
// health, and within the same reach test a strike uses.
@(private = "file")
server_heal_ally_ok :: proc(server: ^Server, caster_id, target_id: Entity_ID, def: ^Spell_Def, eye, look: vec3) -> bool {
	if !entity_alive(&server.world, target_id) {
		return false
	}
	if server.world.characters[target_id].health >= HEALTH_MAX {
		return false
	}
	if !spell_target_valid_for_filter(.Friendly, caster_id, target_id, server.world.teams[caster_id], server.world.teams[target_id]) {
		return false
	}
	return strike_target_in_reach(def, eye, look, server.world.characters[target_id].pos)
}

// Land a strike: the target takes the hit, anyone hostile around them takes
// the splash, and the bolt is queued for every client's snapshots.
@(private = "file")
server_strike :: proc(server: ^Server, caster_id, target_id: Entity_ID, def: ^Spell_Def, charge: f32) {
	damage := def.damage * charge
	combat_apply_damage(&server.world, caster_id, target_id, def.id, damage)
	target := server.world.characters[target_id]
	if SERVER_VERBOSE {
		server_log("[Combat] %s from %d hit %d for %.0f (%.0f HP left)",
			def.short_name, caster_id, target_id, damage, target.health)
	}

	at := strike_center(target.pos)
	splash_damage(&server.world, at, caster_id, server.world.teams[caster_id], target_id, def.id,
		damage * def.aoe_damage_frac, def.aoe_radius, def.knockback)

	// Record it where the bolt meets the ground: the target's feet.
	slot := 0
	oldest: f32 = -1
	for i in 0..<MAX_STRIKES {
		s := &server.strikes[i]
		if !s.live {
			slot = i
			break
		}
		if s.age > oldest {
			oldest = s.age
			slot = i
		}
	}
	server.strike_seq += 1
	server.strikes[slot] = Strike{live = true, seq = server.strike_seq, owner_id = caster_id, pos = target.pos}
}

@(private = "file")
server_age_strikes :: proc(server: ^Server, dt: f32) {
	for i in 0..<MAX_STRIKES {
		s := &server.strikes[i]
		if !s.live {
			continue
		}
		s.age += dt
		if s.age >= STRIKE_LINGER_SEC {
			s.live = false
		}
	}
}

@(private = "file")
blink_spot_free :: proc(pos: vec3) -> bool {
	offs := [4]vec3{
		{0, 0, 0.12},
		{0, 0, CHARACTER_HEIGHT_M * 0.5},
		{0, 0, CHARACTER_HEIGHT_M * 0.9},
		{0, 0, 0.6},
	}
	for o in offs {
		if !world_point_free(pos + o, CHARACTER_RADIUS_M + 0.05) {
			return false
		}
	}
	return true
}

// ---------------------------------------------------------------------------
// Main loop

server_avg_tick_time :: proc(server: ^Server) -> f32 {
	count := min(int(server.total_ticks), len(server.tick_times_ms))
	if count == 0 {
		return 0
	}
	sum: f32 = 0
	for i in 0..<count {
		sum += server.tick_times_ms[i]
	}
	return sum / f32(count)
}

server_max_tick_time :: proc(server: ^Server) -> f32 {
	count := min(int(server.total_ticks), len(server.tick_times_ms))
	m: f32 = 0
	for i in 0..<count {
		m = max(m, server.tick_times_ms[i])
	}
	return m
}

server_run :: proc(server: ^Server) {
	fmt.println("\n=== Server tick loop (60Hz) — Ctrl+C to stop ===\n")

	tick_interval := time.Duration(1_000_000_000 / SIMULATION_TICK_RATE)
	next_tick := time.tick_now()
	last_stats := time.tick_now()

	for server.running {
		if time.tick_since(next_tick) >= 0 {
			server_tick(server)
			next_tick._nsec += i64(tick_interval)
			if time.tick_since(next_tick) >= tick_interval * 4 {
				fmt.eprintln("WARNING: tick overrun, resyncing clock")
				next_tick = time.tick_now()
			}
		}

		if time.tick_since(last_stats) >= time.Second * 10 {
			server_print_stats(server)
			last_stats = time.tick_now()
		}

		// Sleep only if we have comfortable slack until the next tick
		remaining := time.Duration(-time.tick_since(next_tick))
		if remaining > time.Millisecond * 2 {
			time.sleep(time.Millisecond)
		}
	}

	server_shutdown(server)
}

server_print_stats :: proc(server: ^Server) {
	uptime_sec := f64(time.tick_since(server.start_time)) / f64(time.Second)
	humans := server_human_counts(server)
	fmt.printf("[Stats] up %.0fs | tick %d | entities %d | clients %d (%d/%d/%d) | proj %d | tick avg %.3fms max %.3fms | %s %.0f/%.0f/%.0f\n",
		uptime_sec, server.tick_id, server.world.count, server.client_count,
		humans[0], humans[1], humans[2], server.projectiles.count,
		server_avg_tick_time(server), server_max_tick_time(server),
		server.match.state == .Active ? "ACTIVE" : (server.match.state == .Waiting ? "WARMUP" : "ENDED"),
		server.match.essence[0], server.match.essence[1], server.match.essence[2])

	// One bot per team so lane traversal problems are visible in the log
	fmt.printf("        bots:")
	for team in TEAMS {
		for i in 0..<MAX_BOTS {
			b := &server.bots[i]
			if b.active && b.team == team {
				c := server.world.characters[b.id]
				fmt.printf(" %s(%.0f,%.0f %v obj%d%s)", team_name(team), c.pos.x, c.pos.y, b.mode, b.objective, c.dead ? " dead" : "")
				break
			}
		}
	}
	fmt.println()
}

server_shutdown :: proc(server: ^Server) {
	server.running = false
	network_shutdown(&server.network)
	fmt.println("Server stopped.")
}

main_server :: proc() {
	server := new(Server)
	if !server_init(server, server_port_from_env()) {
		fmt.eprintln("Failed to initialize server")
		return
	}
	server_run(server)
}
