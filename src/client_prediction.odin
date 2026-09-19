package main

import "core:math"

// Client-side world: local prediction + reconciliation, remote entity
// interpolation on an estimated server clock, projectile extrapolation and
// impact bookkeeping. No rendering here; the graphical client reads this.

PREDICTION_BUFFER_SIZE :: 128
INTERP_BUFFER_SIZE     :: 12
INTERP_DELAY_TICKS     :: f64(5.0)     // ~83 ms behind the newest snapshot
REMOTE_TIMEOUT_SEC     :: f64(1.0)
MAX_CLIENT_IMPACTS     :: 8

TARGET_RANGE_M         :: f32(100.0)
// Selection is deliberately more forgiving than a projectile hit: picking the
// wrong name off the HUD costs nothing, sweeping past the right one is annoying.
TARGET_RADIUS_M        :: CHARACTER_RADIUS_M * 1.8

// Connection state machine shared by the graphical and headless clients.
Client_Phase :: enum u8 {
	Connecting,   // pinging the server for a lobby packet
	Team_Select,  // lobby known, waiting for the player to pick
	Joining,      // join sent, waiting for welcome
	Playing,
	In_Menu,      // paused, menu open
}

Client_Prediction :: struct {
	input_buffer: [PREDICTION_BUFFER_SIZE]Input_State,
	tick_buffer:  [PREDICTION_BUFFER_SIZE]u32,
	buffer_head:  int,

	predicted_char: Character_State,
	prev_char:      Character_State,   // state before the newest predicted tick
	smooth_offset:  vec3,              // visual correction, decays to zero
	initialized:    bool,

	last_ack_tick:      u32,
	last_server_health: f32,
	last_server_dead:   bool,

	mispredict_count:  int,
	total_predictions: int,

	// Events for the presentation layer (consumed each frame)
	teleported:   bool,
	respawned:    bool,
	died:         bool,
	damage_taken: f32,
	healed:       f32,
}

Remote_Entity :: struct {
	id:        Entity_ID,
	team:      Team_ID,
	is_bot:    bool,
	states:    [INTERP_BUFFER_SIZE]Character_State, // newest first
	ticks:     [INTERP_BUFFER_SIZE]u32,
	count:     int,
	display_state: Character_State,
	active:    bool,
	last_seen: f64,

	// What they are winding up, for the orb drawn in their hand. Taken from the
	// newest snapshot rather than interpolated with the body: a wind-up runs
	// for the better part of a second, so the interpolation delay is invisible
	// in it, and a telegraph that arrives early is fairer than one that is late.
	channel_spell: Spell_ID,
	channel_frac:  f32,
}

Client_Projectile :: struct {
	snap:      Snapshot_Projectile,
	recv_time: f64,
	present:   bool,
}

Client_Impact :: struct {
	pos:   vec3,
	age:   f32,      // 1 → 0
	spell: Spell_ID,
	live:  bool,
}

// A lightning bolt being drawn: sky to `pos`, gone in STRIKE_FLASH_SEC.
Client_Strike :: struct {
	pos:  vec3,
	life: f32,       // 1 → 0
	live: bool,
}

MAX_CLIENT_STRIKES :: 4
STRIKE_FLASH_SEC   :: f32(0.45)
// Strike sequence numbers already spawned. The server replays a strike for a
// third of a second so a lost snapshot does not lose it; this keeps the
// replays from spawning it again.
SEEN_STRIKES       :: 16

Client_World :: struct {
	local_entity_id: Entity_ID,
	local_team:      Team_ID,
	prediction:      Client_Prediction,

	remote_entities: [MAX_ENTITIES]Remote_Entity,

	client_tick:     u32,
	local_time:      f64,

	// Server clock estimate (in ticks) for remote interpolation
	server_tick_offset: f64,
	have_server_tick:   bool,
	latest_server_tick: u32,

	projectiles:      [MAX_SNAPSHOT_PROJECTILES]Client_Projectile,
	projectile_count: int,

	impacts:          [MAX_CLIENT_IMPACTS]Client_Impact,
	hit_marker:       f32,

	strikes:          [MAX_CLIENT_STRIKES]Client_Strike,
	seen_strikes:     [SEEN_STRIKES]u8,
	seen_strike_head: int,
	seen_strike_count: int,

	// Beams lit as of the newest snapshot. State, not events: each snapshot
	// replaces the lot, and one that has gone stale is not drawn.
	beams:            [MAX_SNAPSHOT_BEAMS]Snapshot_Beam,
	beam_count:       int,
	beam_time:        f64,

	game_state:       Server_GameState_Packet,
	have_game_state:  bool,

	// The client's own copy of the ore towers, node HP only. GameState
	// carries all seven towers; dirty towers also ride the 30 Hz
	// snapshot so cover you are standing in does not wait on the HUD packet.
	towers:           Tower_World,

	// Ore on the floor, straight from the newest snapshot. State rather than
	// events, so a lump that stops being sent has been picked up or timed out.
	chunks:           [MAX_SNAPSHOT_CHUNKS]Client_Chunk,
	chunk_count:      int,
	chunk_time:       f64,

	// Lane minions, same deal as the ore: interest-managed state, replaced
	// whole every snapshot. Smoothed towards rather than extrapolated from,
	// because a minion that has stopped to rebuild a tower stops dead and
	// guessing it forward would slide it into the rock.
	minions:          [MAX_SNAPSHOT_MINIONS]Client_Minion,
	minion_count:     int,

	// Sticky soft target. Drawn under the crosshair, and sent up with every
	// input so a targeted spell lands on it once the server has validated it.
	target_id:        Entity_ID,

	// Who is in the match and how they are doing, from the roster packet.
	// Indexed by entity id and independent of what is in view, so a name stays
	// put when its owner walks behind a wall and the scoreboard lists the whole
	// match rather than the neighbours.
	roster:           [MAX_ENTITIES]Client_Roster_Slot,

	// Recent combat addressed to the local player.
	combat_log:       [MAX_COMBAT_LOG_LINES]Client_Combat_Line,
}

Client_Roster_Slot :: struct {
	present: bool,
	team:    Team_ID,
	is_bot:  bool,
	name:    Player_Name,
	stats:   Combat_Stats,
}

// Roughly "close the gap in a tenth of a second", which is three snapshots and
// about the same distance a minion covers between two of them.
MINION_SMOOTH_RATE :: f32(12.0)
MINION_SNAP_DIST   :: f32(4.0)

// A lane minion as the client draws it. `pos` and `yaw` are the smoothed ones
// that get rendered; `target_pos` is where the last snapshot put it.
Client_Minion :: struct {
	present:    bool,
	id:         Minion_ID,
	kind:       Minion_Kind,
	team:       Team_ID,
	pos:        vec3,
	target_pos: vec3,
	yaw:        f32,
	target_yaw: f32,
	hp:         f32,
}

// A lump of ore as the client draws it. Carries the snapshot velocity so a
// falling chunk keeps moving between snapshots instead of stepping at 30 Hz.
Client_Chunk :: struct {
	present: bool,
	id:      Ore_Chunk_ID,
	ore:     Ore_Kind,
	pos:     vec3,
	vel:     vec3,
	radius:  f32,
	rest:    bool,
	seed:    f32,
}

MAX_COMBAT_LOG_LINES :: 5
COMBAT_LOG_HOLD_SEC  :: f32(4.0)
COMBAT_LOG_FADE_SEC  :: f32(1.0)

// One line of the log. `seq` is the server's name for it: an arriving event
// with a seq already on screen updates that line instead of adding another,
// which is both how a repeated packet is ignored and how a beam shows up as
// one tally climbing rather than a wall of identical lines.
Client_Combat_Line :: struct {
	live:       bool,
	seq:        u8,
	event_type: Combat_Event_Type,
	other_id:   Entity_ID,
	spell_id:   Spell_ID,
	damage:     u16,
	age:        f32,
}

// ---------------------------------------------------------------------------
// Prediction

client_prediction_init :: proc(pred: ^Client_Prediction) {
	pred^ = {}
}

client_prediction_push_input :: proc(pred: ^Client_Prediction, tick: u32, input: Input_State) {
	idx := pred.buffer_head % PREDICTION_BUFFER_SIZE
	pred.input_buffer[idx] = input
	pred.tick_buffer[idx] = tick
	pred.buffer_head += 1
}

// Advance the local player one tick with an (already quantized) input.
client_prediction_step :: proc(pred: ^Client_Prediction, tick: u32, input: Input_State) {
	client_prediction_push_input(pred, tick, input)
	pred.prev_char = pred.predicted_char
	simulate_character_step(&pred.predicted_char, input, SIMULATION_DT)
	pred.total_predictions += 1
}

// Rewind to the authoritative state and replay every input the server has
// not applied yet (tick > ack_input_tick).
client_prediction_reconcile :: proc(pred: ^Client_Prediction, ack_input_tick: u32, server_state: Character_State) {
	if !pred.initialized {
		pred.predicted_char = server_state
		pred.prev_char = server_state
		pred.initialized = true
		pred.last_server_health = server_state.health
		pred.last_server_dead = server_state.dead
		pred.last_ack_tick = ack_input_tick
		return
	}

	// Damage / heal / death events. Health coming back while dead is a respawn
	// refilling the bar, which has its own flash, so it is not a heal. The
	// killing blow still counts as damage so the hurt flash (and SFX) fire.
	if server_state.health < pred.last_server_health - 0.5 && !pred.last_server_dead {
		pred.damage_taken += pred.last_server_health - server_state.health
	}
	if server_state.health > pred.last_server_health + 0.5 && !pred.last_server_dead {
		pred.healed += server_state.health - pred.last_server_health
	}
	if !pred.last_server_dead && server_state.dead {
		pred.died = true
	}
	if pred.last_server_dead && !server_state.dead {
		pred.respawned = true
	}
	pred.last_server_health = server_state.health
	pred.last_server_dead = server_state.dead
	pred.last_ack_tick = ack_input_tick

	old_pos := pred.predicted_char.pos
	pred.predicted_char = server_state

	oldest := pred.buffer_head - PREDICTION_BUFFER_SIZE
	if oldest < 0 {
		oldest = 0
	}
	for i in oldest ..< pred.buffer_head {
		idx := i % PREDICTION_BUFFER_SIZE
		if pred.tick_buffer[idx] > ack_input_tick {
			simulate_character_step(&pred.predicted_char, pred.input_buffer[idx], SIMULATION_DT)
		}
	}

	delta := old_pos - pred.predicted_char.pos
	dist := len_vec3(delta)
	if dist > 0.02 {
		pred.mispredict_count += 1
	}
	if dist > 2.5 {
		// Blink / respawn / hard correction: snap
		pred.smooth_offset = {}
		pred.prev_char.pos = pred.predicted_char.pos
		if !pred.respawned {
			pred.teleported = true
		}
		// A round reset moves everyone and refills them while they are alive;
		// that is a respawn, not a heal, and it has its own flash.
		pred.healed = 0
	} else {
		// Keep the rendered position continuous; the offset bleeds off over time
		pred.smooth_offset += delta
		l := len_vec3(pred.smooth_offset)
		if l > 1.0 {
			pred.smooth_offset = pred.smooth_offset * (1.0 / l)
		}
		pred.prev_char.pos -= delta
	}
}

// Decay the visual correction offset. Called once per rendered frame.
client_prediction_decay_offset :: proc(pred: ^Client_Prediction, dt: f32) {
	k := math.exp(-dt * 16.0)
	pred.smooth_offset *= k
	if len2_vec3(pred.smooth_offset) < 1e-6 {
		pred.smooth_offset = {}
	}
}

// Position to render the local player at this frame: interpolate across the
// most recent tick and add the smoothing offset.
client_prediction_render_pos :: proc(pred: ^Client_Prediction, alpha: f32) -> vec3 {
	return lerpv3(pred.prev_char.pos, pred.predicted_char.pos, clampf(alpha, 0, 1)) + pred.smooth_offset
}

client_prediction_stats :: proc(pred: ^Client_Prediction) -> (mispredict_rate: f32, total: int) {
	if pred.total_predictions == 0 {
		return 0, 0
	}
	return f32(pred.mispredict_count) / f32(pred.total_predictions), pred.total_predictions
}

// ---------------------------------------------------------------------------
// Remote entities

remote_entity_add_snapshot :: proc(remote: ^Remote_Entity, tick: u32, state: Character_State) {
	if remote.count > 0 && tick <= remote.ticks[0] {
		return // out of order / duplicate
	}
	for i := min(remote.count, INTERP_BUFFER_SIZE - 1); i > 0; i -= 1 {
		remote.states[i] = remote.states[i - 1]
		remote.ticks[i] = remote.ticks[i - 1]
	}
	remote.states[0] = state
	remote.ticks[0] = tick
	remote.count = min(remote.count + 1, INTERP_BUFFER_SIZE)
}

@(private = "file")
lerp_angle :: proc(a, b, t: f32) -> f32 {
	return wrap_angle(a + wrap_angle(b - a) * t)
}

@(private = "file")
lerp_state :: proc(older, newer: Character_State, t: f32) -> Character_State {
	out := newer
	out.pos = lerpv3(older.pos, newer.pos, t)
	out.vel = lerpv3(older.vel, newer.vel, t)
	out.yaw = lerp_angle(older.yaw, newer.yaw, t)
	out.pitch = lerpf(older.pitch, newer.pitch, t)
	return out
}

// Compute display_state for the estimated server render tick.
remote_entity_interpolate :: proc(remote: ^Remote_Entity, render_tick: f64) {
	if remote.count == 0 {
		return
	}
	if remote.count == 1 {
		remote.display_state = remote.states[0]
		return
	}

	newest_tick := f64(remote.ticks[0])
	if render_tick >= newest_tick {
		// Ahead of the data: extrapolate briefly along velocity
		s := remote.states[0]
		dt := f32(min(render_tick - newest_tick, 6.0) / f64(SIMULATION_TICK_RATE))
		if !s.dead {
			s.pos += s.vel * dt
			if s.pos.z < WORLD_FLOOR_Z {
				s.pos.z = WORLD_FLOOR_Z
			}
		}
		remote.display_state = s
		return
	}

	for i in 0..<remote.count - 1 {
		newer_t := f64(remote.ticks[i])
		older_t := f64(remote.ticks[i + 1])
		if render_tick <= newer_t && render_tick >= older_t {
			span := newer_t - older_t
			t := span > 0 ? f32((render_tick - older_t) / span) : 1
			remote.display_state = lerp_state(remote.states[i + 1], remote.states[i], t)
			return
		}
	}
	// Older than everything we have
	remote.display_state = remote.states[remote.count - 1]
}

// ---------------------------------------------------------------------------
// World

// Takes a pointer rather than returning a value: Client_World is large
// enough that copying it through a return slot is a bad habit.
client_world_init :: proc(world: ^Client_World) {
	world^ = {}
	world.local_entity_id = INVALID_ENTITY
	world.target_id = INVALID_ENTITY
	client_prediction_init(&world.prediction)
	tower_world_init(&world.towers)
}

client_world_reset_session :: proc(world: ^Client_World) {
	world.local_entity_id = INVALID_ENTITY
	world.local_team = .None
	client_prediction_init(&world.prediction)
	world.remote_entities = {}
	world.projectiles = {}
	world.projectile_count = 0
	world.impacts = {}
	world.strikes = {}
	world.seen_strike_count = 0
	world.seen_strike_head = 0
	world.beam_count = 0
	world.have_server_tick = false
	world.have_game_state = false
	world.target_id = INVALID_ENTITY
	world.roster = {}
	world.combat_log = {}
	world.chunk_count = 0
	world.chunks = {}
	world.minion_count = 0
	world.minions = {}
	// A new session is a new round's worth of towers. GameState on
	// the next HUD packet is the whole catch-up; there is no resync path.
	tower_world_reset(&world.towers)
}

client_world_apply_gamestate_towers :: proc(world: ^Client_World, gs: ^Server_GameState_Packet) {
	for i in 0 ..< MAX_PYLONS {
		t := tower_get(&world.towers, Pylon_ID(i))
		if t != nil {
			tower_unpack_nodes(t, gs.towers[i].node_hp[:])
		}
	}
}

client_world_apply_snapshot_towers :: proc(world: ^Client_World, snapshot: ^Server_Snapshot_Packet) {
	n := min(int(snapshot.tower_count), MAX_SNAPSHOT_OCC_PYLONS)
	for i in 0 ..< n {
		tw := &snapshot.towers[i]
		t := tower_get(&world.towers, tw.tower_id)
		if t != nil {
			tower_unpack_nodes(t, tw.node_hp[:])
		}
	}
}

// Estimated server tick at which remote entities should be displayed.
client_world_render_tick :: proc(world: ^Client_World) -> f64 {
	if !world.have_server_tick {
		return 0
	}
	return world.local_time * f64(SIMULATION_TICK_RATE) + world.server_tick_offset - INTERP_DELAY_TICKS
}

@(private = "file")
client_world_note_server_tick :: proc(world: ^Client_World, tick: u32) {
	now_ticks := world.local_time * f64(SIMULATION_TICK_RATE)
	sample := f64(tick) - now_ticks
	if !world.have_server_tick {
		world.server_tick_offset = sample
		world.have_server_tick = true
	} else if abs(sample - world.server_tick_offset) > 10 {
		world.server_tick_offset = sample
	} else {
		// Bias toward the newest arrivals so we rarely run ahead of data
		gain := sample > world.server_tick_offset ? 0.15 : 0.04
		world.server_tick_offset += (sample - world.server_tick_offset) * gain
	}
	world.latest_server_tick = max(world.latest_server_tick, tick)
}

client_world_apply_snapshot :: proc(world: ^Client_World, snapshot: ^Server_Snapshot_Packet) {
	client_world_note_server_tick(world, snapshot.tick_id)

	for i in 0..<int(snapshot.entity_count) {
		entity := &snapshot.entities[i]
		state := Character_State{
			pos        = entity.pos,
			vel        = entity.vel,
			yaw        = entity.yaw,
			pitch      = entity.pitch,
			on_ground  = entity.on_ground,
			active     = true,
			health     = entity.health,
			mana       = entity.mana,
			stamina    = entity.stamina,
			slow_ticks = entity.slow_ticks,
			dead       = entity.dead,
		}

		if entity.id == world.local_entity_id {
			world.local_team = entity.team
			client_prediction_reconcile(&world.prediction, snapshot.ack_input_tick, state)
			continue
		}

		if entity.id >= MAX_ENTITIES {
			continue
		}
		remote := &world.remote_entities[entity.id]
		if !remote.active {
			remote^ = {}
			remote.id = entity.id
			remote.active = true
		}
		remote.team = entity.team
		remote.is_bot = entity.is_bot
		remote.last_seen = world.local_time
		remote.channel_spell = entity.channel_spell
		remote.channel_frac = entity.channel_frac
		remote_entity_add_snapshot(remote, snapshot.tick_id, state)
	}

	client_world_apply_projectiles(world, snapshot)
	client_world_apply_strikes(world, snapshot)
	client_world_apply_beams(world, snapshot)
	client_world_apply_combat_events(world, snapshot)
	client_world_apply_snapshot_towers(world, snapshot)
	client_world_apply_chunks(world, snapshot)
	client_world_apply_minions(world, snapshot)
}

@(private = "file")
client_world_apply_chunks :: proc(world: ^Client_World, snapshot: ^Server_Snapshot_Packet) {
	// Ore is interest-managed state: the newest snapshot is the whole truth
	// about what is nearby, so anything not in it is gone from view.
	prev := world.chunks
	prev_n := world.chunk_count
	world.chunks = {}
	world.chunk_count = int(snapshot.chunk_count)
	world.chunk_time = world.local_time
	for i in 0..<world.chunk_count {
		s := &snapshot.chunks[i]
		c := &world.chunks[i]
		c.present = true
		c.id = s.id
		c.ore = s.ore
		c.pos = s.pos
		c.vel = s.vel
		c.radius = s.radius
		c.rest = s.rest
		// Keep the lump looking like the same rock across snapshots.
		c.seed = f32(hash_u32(u32(s.id) * 2246822519) & 0xFFFF) / f32(0x10000) * 8
		for k in 0..<prev_n {
			if prev[k].present && prev[k].id == s.id {
				c.seed = prev[k].seed
				break
			}
		}
	}
}

@(private = "file")
client_world_apply_minions :: proc(world: ^Client_World, snapshot: ^Server_Snapshot_Packet) {
	prev := world.minions
	prev_n := world.minion_count
	world.minions = {}
	world.minion_count = int(snapshot.minion_count)
	for i in 0..<world.minion_count {
		s := &snapshot.minions[i]
		m := &world.minions[i]
		m.present = true
		m.id = s.id
		m.kind = s.kind
		m.team = s.team
		m.target_pos = s.pos
		m.target_yaw = s.yaw
		m.hp = s.hp
		// A body we have seen before keeps the position it was drawn at and
		// walks to the new one. One we have not just appears there, which is
		// right: it either spawned or came round a corner into interest range.
		m.pos = s.pos
		m.yaw = s.yaw
		for k in 0..<prev_n {
			if prev[k].present && prev[k].id == s.id {
				m.pos = prev[k].pos
				m.yaw = prev[k].yaw
				break
			}
		}
	}
}

// Walk the drawn minions towards the last thing the server said. A fixed rate
// rather than a spring: the error is bounded by one snapshot of travel, and a
// constant closing speed gets rid of it in about that long without overshoot.
client_world_step_minions :: proc(world: ^Client_World, dt: f32) {
	blend := clampf(dt * MINION_SMOOTH_RATE, 0, 1)
	for i in 0..<world.minion_count {
		m := &world.minions[i]
		if !m.present {
			continue
		}
		d := m.target_pos - m.pos
		// A jump no interpolation can explain -- a teleport, or an id reused
		// across a round reset -- is snapped rather than slid across the map.
		if len2_vec3(d) > MINION_SNAP_DIST * MINION_SNAP_DIST {
			m.pos = m.target_pos
			m.yaw = m.target_yaw
		} else {
			m.pos += d * blend
			m.yaw += wrap_angle(m.target_yaw - m.yaw) * blend
		}
	}
}

// Advance the ore we were last told about. Chunks are not predicted -- the
// server owns them -- but extrapolating the airborne ones keeps a shower of
// rock smooth between snapshots.
client_world_step_chunks :: proc(world: ^Client_World, dt: f32) {
	for i in 0..<world.chunk_count {
		c := &world.chunks[i]
		if !c.present || c.rest {
			continue
		}
		c.vel.z -= CHUNK_GRAVITY * dt
		c.pos += c.vel * dt
		if c.pos.z < WORLD_FLOOR_Z + c.radius {
			c.pos.z = WORLD_FLOOR_Z + c.radius
			c.vel = {}
		}
	}
}

// The roster replaces wholesale: it is the server's complete answer to "who is
// here", so anyone missing from it has left.
client_world_apply_roster :: proc(world: ^Client_World, roster: ^Server_Roster_Packet) {
	world.roster = {}
	for i in 0..<int(roster.count) {
		e := &roster.entries[i]
		if e.id == INVALID_ENTITY || e.id >= MAX_ENTITIES {
			continue
		}
		world.roster[e.id] = Client_Roster_Slot{
			present = true,
			team    = e.team,
			is_bot  = e.is_bot,
			name    = e.name,
			stats   = e.stats,
		}
	}
}

// What to call an entity. Prefers the roster, falls back to the id, and works
// for the local player and bots alike.
client_world_name :: proc(world: ^Client_World, id: Entity_ID) -> string {
	if id == INVALID_ENTITY || id >= MAX_ENTITIES {
		return "?"
	}
	slot := &world.roster[id]
	return player_name_display(&slot.name, id, slot.is_bot)
}

@(private = "file")
client_world_apply_combat_events :: proc(world: ^Client_World, snapshot: ^Server_Snapshot_Packet) {
	for i in 0..<int(snapshot.combat_event_count) {
		evt := &snapshot.combat_events[i]

		// A line we already have: the server is either replaying it against
		// packet loss or the tally has grown. Either way, refresh in place.
		existing: ^Client_Combat_Line
		for k in 0..<MAX_COMBAT_LOG_LINES {
			if world.combat_log[k].live && world.combat_log[k].seq == evt.seq {
				existing = &world.combat_log[k]
				break
			}
		}
		if existing != nil {
			if evt.damage > existing.damage {
				existing.damage = evt.damage
				existing.age = 0
			}
			continue
		}

		// Otherwise take a free line, else the one closest to fading out.
		slot := 0
		oldest: f32 = -1
		for k in 0..<MAX_COMBAT_LOG_LINES {
			if !world.combat_log[k].live {
				slot = k
				break
			}
			if world.combat_log[k].age > oldest {
				oldest = world.combat_log[k].age
				slot = k
			}
		}
		world.combat_log[slot] = Client_Combat_Line{
			live       = true,
			seq        = evt.seq,
			event_type = evt.event_type,
			other_id   = evt.other_id,
			spell_id   = evt.spell_id,
			damage     = evt.damage,
		}
	}
}

BEAM_STALE_SEC :: f64(0.2)

@(private = "file")
client_world_apply_beams :: proc(world: ^Client_World, snapshot: ^Server_Snapshot_Packet) {
	world.beam_count = int(snapshot.beam_count)
	world.beam_time = world.local_time
	for i in 0..<world.beam_count {
		world.beams[i] = snapshot.beams[i]
		// The marker is held up for as long as the beam keeps landing.
		if world.beams[i].owner_id == world.local_entity_id && world.beams[i].hit {
			world.hit_marker = max(world.hit_marker, 0.6)
		}
	}
}

// Are the beams in the world fresh enough to draw?
client_world_beams_current :: proc(world: ^Client_World) -> bool {
	return world.beam_count > 0 && world.local_time - world.beam_time < BEAM_STALE_SEC
}

// The local player's beam, if the server says it is lit.
client_world_local_beam :: proc(world: ^Client_World) -> (beam: ^Snapshot_Beam, lit: bool) {
	if !client_world_beams_current(world) {
		return nil, false
	}
	for i in 0..<world.beam_count {
		if world.beams[i].owner_id == world.local_entity_id {
			return &world.beams[i], true
		}
	}
	return nil, false
}

// Where the local player's own beam ends this frame, traced from the eye and
// look the server will use against the bodies the player is looking at. The
// server decides whether the beam is lit at all; drawing its far end from a
// round-trip-old snapshot would have it trail the crosshair.
client_world_beam_end :: proc(world: ^Client_World, def: ^Spell_Def, eye, look: vec3) -> (end: vec3, on_body: bool) {
	reach := world_ray_hit(eye, look, def.range)
	for i in 1..<MAX_ENTITIES {
		remote := &world.remote_entities[i]
		if !remote.active || remote.display_state.dead || Entity_ID(i) == world.local_entity_id {
			continue
		}
		if !teams_are_enemies(world.local_team, remote.team) {
			continue
		}
		if dist, hit := ray_cylinder_hit(eye, look, remote.display_state.pos, CHARACTER_RADIUS_M, CHARACTER_HEIGHT_M, reach); hit {
			reach = dist
			on_body = true
		}
	}
	// Same rule as the server: a hostile minion in front of the crosshair
	// is cover, and the beam tip sits on that body.
	for i in 0..<world.minion_count {
		m := &world.minions[i]
		if !m.present || !teams_are_enemies(world.local_team, m.team) {
			continue
		}
		if dist, hit := ray_cylinder_hit(eye, look, m.pos, MINION_RADIUS_M, MINION_HEIGHT_M, reach); hit {
			reach = dist
			on_body = true
		}
	}
	return eye + look * reach, on_body
}

@(private = "file")
client_world_apply_strikes :: proc(world: ^Client_World, snapshot: ^Server_Snapshot_Packet) {
	for i in 0..<int(snapshot.strike_count) {
		s := &snapshot.strikes[i]
		seen := false
		for k in 0..<world.seen_strike_count {
			if world.seen_strikes[k] == s.seq {
				seen = true
				break
			}
		}
		if seen {
			continue
		}
		world.seen_strikes[world.seen_strike_head] = s.seq
		world.seen_strike_head = (world.seen_strike_head + 1) % SEEN_STRIKES
		world.seen_strike_count = min(world.seen_strike_count + 1, SEEN_STRIKES)

		client_world_add_strike(world, s.pos)
		// The ground flash and its light come from the impact path; the bolt
		// itself is drawn from the strike.
		client_world_add_impact(world, s.pos + vec3{0, 0, 0.4}, .Call_Lightning)
		if s.owner_id == world.local_entity_id {
			world.hit_marker = 1
		}
	}
}

@(private = "file")
client_world_add_strike :: proc(world: ^Client_World, pos: vec3) {
	slot := 0
	oldest_life: f32 = 2
	for i in 0..<MAX_CLIENT_STRIKES {
		s := &world.strikes[i]
		if !s.live {
			slot = i
			break
		}
		if s.life < oldest_life {
			oldest_life = s.life
			slot = i
		}
	}
	world.strikes[slot] = Client_Strike{pos = pos, life = 1, live = true}
}

@(private = "file")
client_world_apply_projectiles :: proc(world: ^Client_World, snapshot: ^Server_Snapshot_Packet) {
	for i in 0..<world.projectile_count {
		world.projectiles[i].present = false
	}

	incoming := snapshot.projectiles[:int(snapshot.projectile_count)]
	for p in incoming {
		found := false
		for i in 0..<world.projectile_count {
			if world.projectiles[i].snap.id == p.id {
				world.projectiles[i].snap = p
				world.projectiles[i].recv_time = world.local_time
				world.projectiles[i].present = true
				found = true
				break
			}
		}
		if !found && world.projectile_count < MAX_SNAPSHOT_PROJECTILES {
			world.projectiles[world.projectile_count] = Client_Projectile{snap = p, recv_time = world.local_time, present = true}
			world.projectile_count += 1
		}
	}

	// Anything that vanished has hit something (or expired): spawn an impact
	for i := 0; i < world.projectile_count; {
		cp := &world.projectiles[i]
		if cp.present {
			i += 1
			continue
		}
		at := client_projectile_pos(cp, world.local_time)
		client_world_add_impact(world, at, cp.snap.spell_id)

		if cp.snap.owner_id == world.local_entity_id {
			for r in 0..<MAX_ENTITIES {
				remote := &world.remote_entities[r]
				if !remote.active || remote.display_state.dead {
					continue
				}
				d := remote.display_state.pos + vec3{0, 0, CHARACTER_HEIGHT_M * 0.5} - at
				if len2_vec3(d) < 1.6 * 1.6 {
					world.hit_marker = 1
					break
				}
			}
		}

		last := world.projectile_count - 1
		if i != last {
			world.projectiles[i] = world.projectiles[last]
		}
		world.projectile_count -= 1
	}
}

// Extrapolate between snapshots along the same ballistic arc the server uses.
client_projectile_pos :: proc(cp: ^Client_Projectile, now: f64) -> vec3 {
	dt := f32(clamp(now - cp.recv_time, 0, 0.25))
	pos := cp.snap.pos + cp.snap.vel * dt
	pos.z += 0.5 * PROJECTILE_GRAVITY_Z * SPELL_DEFS[cp.snap.spell_id].proj_gravity * dt * dt
	return pos
}

client_world_add_impact :: proc(world: ^Client_World, pos: vec3, spell: Spell_ID) {
	slot := 0
	oldest_age: f32 = 2
	for i in 0..<MAX_CLIENT_IMPACTS {
		im := &world.impacts[i]
		if !im.live {
			slot = i
			break
		}
		if im.age < oldest_age {
			oldest_age = im.age
			slot = i
		}
	}
	world.impacts[slot] = Client_Impact{pos = pos, age = 1, spell = spell, live = true}
}

// Per-frame bookkeeping: interpolation, impact aging, timeouts.
client_world_update :: proc(world: ^Client_World, dt: f32) {
	render_tick := client_world_render_tick(world)
	for i in 0..<MAX_ENTITIES {
		remote := &world.remote_entities[i]
		if !remote.active {
			continue
		}
		if world.local_time - remote.last_seen > REMOTE_TIMEOUT_SEC {
			remote.active = false
			continue
		}
		remote_entity_interpolate(remote, render_tick)
	}

	client_world_step_chunks(world, dt)
	client_world_step_minions(world, dt)

	for i in 0..<MAX_CLIENT_IMPACTS {
		im := &world.impacts[i]
		if !im.live {
			continue
		}
		// Bigger blasts linger longer.
		speed: f32 = 2.6
		#partial switch im.spell {
		case .Arcane_Orb:     speed = 1.2
		case .Arcane_Missile: speed = 1.9
		case .Call_Lightning: speed = 1.6
		}
		im.age -= dt * speed
		if im.age <= 0 {
			im.live = false
		}
	}

	for i in 0..<MAX_CLIENT_STRIKES {
		s := &world.strikes[i]
		if !s.live {
			continue
		}
		s.life -= dt / STRIKE_FLASH_SEC
		if s.life <= 0 {
			s.live = false
		}
	}

	world.hit_marker = max(world.hit_marker - dt * 4.0, 0)
	client_prediction_decay_offset(&world.prediction, dt)

	for i in 0..<MAX_COMBAT_LOG_LINES {
		line := &world.combat_log[i]
		if !line.live {
			continue
		}
		line.age += dt
		if line.age >= COMBAT_LOG_HOLD_SEC + COMBAT_LOG_FADE_SEC {
			line^ = {}
		}
	}

	if !client_world_target_valid(world, world.target_id) {
		world.target_id = INVALID_ENTITY
	}
}

// ---------------------------------------------------------------------------
// Sticky soft target
//
// The crosshair latches onto the nearest entity it touches and holds it until
// it touches another one -- aim wobble during a wind-up must not lose the
// target that the cast was meant for.

client_world_target_valid :: proc(world: ^Client_World, id: Entity_ID) -> bool {
	if id == INVALID_ENTITY || id >= MAX_ENTITIES {
		return false
	}
	remote := &world.remote_entities[id]
	return remote.active && !remote.display_state.dead
}

// Is the current sticky target valid for the given spell's targeting filter?
client_world_target_valid_for_spell :: proc(world: ^Client_World, id: Entity_ID, filter: Spell_Target_Filter) -> bool {
	if !client_world_target_valid(world, id) {
		return false
	}
	remote := &world.remote_entities[id]
	return spell_target_valid_for_filter(filter, world.local_entity_id, id, world.local_team, remote.team)
}

// The current target if it is someone a strike may land on: alive and
// hostile. Where they stand is the caller's question; the server asks the same
// things of its own state, this only keeps the client from winding up or
// releasing a bolt that would be refused.
client_world_strike_target :: proc(world: ^Client_World) -> (remote: ^Remote_Entity, ok: bool) {
	if !client_world_target_valid(world, world.target_id) {
		return nil, false
	}
	remote = &world.remote_entities[world.target_id]
	return remote, teams_are_enemies(world.local_team, remote.team)
}

// The current target if it is someone a heal may land on: alive and friendly.
// Missing health and reach are the caller's question, matching how a strike
// leaves where they stand to the server.
client_world_heal_target :: proc(world: ^Client_World) -> (remote: ^Remote_Entity, ok: bool) {
	if !client_world_target_valid(world, world.target_id) {
		return nil, false
	}
	remote = &world.remote_entities[world.target_id]
	return remote, spell_target_valid_for_filter(
		.Friendly, world.local_entity_id, world.target_id, world.local_team, remote.team)
}

// Is there anyone this heal would actually mend: the local player, or a
// wounded teammate under the crosshair. Range and cover are firing's question.
client_heal_has_work :: proc(world: ^Client_World, local: Character_State) -> bool {
	if local.health < HEALTH_MAX {
		return true
	}
	target, ok := client_world_heal_target(world)
	return ok && target.display_state.health < HEALTH_MAX
}

// Entities are tested at their interpolated display position, so the selection
// follows what the player can actually see rather than the newer server state.
// `filter` determines which entities may be selected: enemies, friendlies, or any.
client_world_acquire_target :: proc(world: ^Client_World, eye: vec3, look_dir: vec3, filter: Spell_Target_Filter) {
	best_dist := TARGET_RANGE_M
	best_id := INVALID_ENTITY
	for i in 1..<MAX_ENTITIES {
		remote := &world.remote_entities[i]
		if !remote.active || remote.display_state.dead {
			continue
		}
		if Entity_ID(i) == world.local_entity_id {
			continue
		}
		// Apply the spell's target filter
		if !spell_target_valid_for_filter(filter, world.local_entity_id, Entity_ID(i), world.local_team, remote.team) {
			continue
		}
		dist, hit := ray_cylinder_hit(
			eye, look_dir, remote.display_state.pos,
			TARGET_RADIUS_M, CHARACTER_HEIGHT_M, best_dist,
		)
		if !hit {
			continue
		}
		best_dist = dist
		best_id = Entity_ID(i)
	}
	if best_id != INVALID_ENTITY {
		world.target_id = best_id
	}
}
