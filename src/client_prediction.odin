package main

import "core:fmt"
import "core:slice"

// Client-side prediction system
// Implements input ring buffer, prediction, and reconciliation against server snapshots

PREDICTION_BUFFER_SIZE :: 128  // Store last 128 ticks of inputs

// Client prediction state
Client_Prediction :: struct {
	// Ring buffer of inputs
	input_buffer:   [PREDICTION_BUFFER_SIZE]Input_State,
	tick_buffer:    [PREDICTION_BUFFER_SIZE]u32,
	buffer_head:    int,  // Next write position
	
	// Local predicted state
	predicted_char: Character_State,
	
	// Last acknowledged state from server
	last_ack_tick:  u32,
	last_ack_state: Character_State,
	
	// Misprediction tracking
	mispredict_count: int,
	total_predictions: int,
}

// Remote entity interpolation buffer
INTERP_BUFFER_SIZE :: 4

Remote_Entity :: struct {
	id:             Entity_ID,
	// Interpolation buffer (newest first)
	states:         [INTERP_BUFFER_SIZE]Character_State,
	ticks:          [INTERP_BUFFER_SIZE]u32,
	buffer_count:   int,
	
	// Current interpolated state
	display_state:  Character_State,
	active:         bool,
}

// Client world state
Client_World :: struct {
	// Local player
	local_entity_id: Entity_ID,
	local_team:      Team_ID,  // Phase 4: client's team
	prediction:      Client_Prediction,
	
	// Remote entities
	remote_entities: [MAX_ENTITIES]Remote_Entity,
	remote_count:    int,
	
	// Client tick
	client_tick:     u32,
	
	// Phase 3: Client-side projectiles (synced from server)
	projectiles:     [32]Snapshot_Projectile,
	projectile_count: int,
	
	// Phase 4: Game state (synced from server)
	game_state:      Server_GameState_Packet,
}

// Initialize client prediction
client_prediction_init :: proc(pred: ^Client_Prediction, initial_state: Character_State) {
	pred.predicted_char = initial_state
	pred.last_ack_state = initial_state
	pred.last_ack_tick = 0
	pred.buffer_head = 0
	pred.mispredict_count = 0
	pred.total_predictions = 0
}

// Store input for this tick in ring buffer
client_prediction_push_input :: proc(pred: ^Client_Prediction, tick: u32, input: Input_State) {
	idx := pred.buffer_head % PREDICTION_BUFFER_SIZE
	pred.input_buffer[idx] = input
	pred.tick_buffer[idx] = tick
	pred.buffer_head += 1
}

// Predict one step forward using stored input
client_prediction_step :: proc(pred: ^Client_Prediction, tick: u32, input: Input_State) {
	// Store input
	client_prediction_push_input(pred, tick, input)
	
	// Apply input to predicted state
	temp_world := Entity_World{}
	temp_world.characters[1] = pred.predicted_char
	temp_world.characters[1].active = true
	temp_world.inputs[1] = input
	
	// Run simulation kernel
	simulate_world_step(&temp_world)
	
	pred.predicted_char = temp_world.characters[1]
	pred.total_predictions += 1
}

// Reconcile with authoritative server state
client_prediction_reconcile :: proc(pred: ^Client_Prediction, server_tick: u32, server_state: Character_State) {
	// Update last acknowledged state
	pred.last_ack_tick = server_tick
	
	// Check for misprediction (position difference threshold)
	pos_diff := len_vec3(pred.last_ack_state.pos - server_state.pos)
	if pos_diff > 0.01 {  // 1cm threshold
		pred.mispredict_count += 1
		fmt.printf("[Prediction] Misprediction detected: %.3fm difference (tick %d)\n", pos_diff, server_tick)
	}
	
	pred.last_ack_state = server_state
	
	// Find inputs after this server tick
	oldest_idx := (pred.buffer_head - PREDICTION_BUFFER_SIZE) if pred.buffer_head >= PREDICTION_BUFFER_SIZE else 0
	
	// Rewind to server state
	pred.predicted_char = server_state
	
	// Replay inputs from server tick to present
	rewind_count := 0
	for i in oldest_idx ..< pred.buffer_head {
		idx := i % PREDICTION_BUFFER_SIZE
		input_tick := pred.tick_buffer[idx]
		
		if input_tick > server_tick {
			// Resimulate this input
			temp_world := Entity_World{}
			temp_world.characters[1] = pred.predicted_char
			temp_world.characters[1].active = true
			temp_world.inputs[1] = pred.input_buffer[idx]
			
			simulate_world_step(&temp_world)
			pred.predicted_char = temp_world.characters[1]
			rewind_count += 1
		}
	}
	
	if rewind_count > 0 {
		fmt.printf("[Prediction] Rewound %d ticks from server state\n", rewind_count)
	}
}

// Initialize remote entity
remote_entity_init :: proc(remote: ^Remote_Entity, id: Entity_ID) {
	remote.id = id
	remote.buffer_count = 0
	remote.active = true
}

// Add snapshot for remote entity
remote_entity_add_snapshot :: proc(remote: ^Remote_Entity, tick: u32, state: Character_State) {
	// Insert at front, shift others back
	for i := min(remote.buffer_count, INTERP_BUFFER_SIZE - 1); i > 0; i -= 1 {
		remote.states[i] = remote.states[i-1]
		remote.ticks[i] = remote.ticks[i-1]
	}
	
	remote.states[0] = state
	remote.ticks[0] = tick
	remote.buffer_count = min(remote.buffer_count + 1, INTERP_BUFFER_SIZE)
}

// Interpolate remote entity state
// render_time is typically current_time - 50-75ms for smooth interpolation
remote_entity_interpolate :: proc(remote: ^Remote_Entity, current_tick: u32, interp_delay_ticks: u32) {
	if remote.buffer_count < 2 {
		// Not enough data, just use most recent
		if remote.buffer_count == 1 {
			remote.display_state = remote.states[0]
		}
		return
	}
	
	// Target tick for interpolation (in the past)
	target_tick := current_tick - interp_delay_ticks
	
	// Find two snapshots to interpolate between
	from_idx := 0
	to_idx := 1
	
	for i in 0..<remote.buffer_count-1 {
		if remote.ticks[i] >= target_tick && remote.ticks[i+1] <= target_tick {
			from_idx = i
			to_idx = i + 1
			break
		}
	}
	
	// Interpolate (linear for now, could use Hermite)
	from_tick := remote.ticks[from_idx]
	to_tick := remote.ticks[to_idx]
	
	if from_tick == to_tick {
		remote.display_state = remote.states[from_idx]
		return
	}
	
	t := f32(target_tick - to_tick) / f32(from_tick - to_tick)
	t = clampf(t, 0, 1)
	
	// Lerp position
	from_state := remote.states[from_idx]
	to_state := remote.states[to_idx]
	
	remote.display_state.pos.x = lerpf(to_state.pos.x, from_state.pos.x, t)
	remote.display_state.pos.y = lerpf(to_state.pos.y, from_state.pos.y, t)
	remote.display_state.pos.z = lerpf(to_state.pos.z, from_state.pos.z, t)
	
	// Lerp angles (could use slerp for better rotation)
	remote.display_state.yaw = lerpf(to_state.yaw, from_state.yaw, t)
	remote.display_state.pitch = lerpf(to_state.pitch, from_state.pitch, t)
	
	// Copy other state
	remote.display_state.vel_z = to_state.vel_z
	remote.display_state.on_ground = to_state.on_ground
	remote.display_state.active = true
}

// Initialize client world
client_world_init :: proc() -> Client_World {
	world := Client_World{}
	world.local_entity_id = INVALID_ENTITY
	world.client_tick = 0
	world.remote_count = 0
	return world
}

// Process server snapshot
client_world_apply_snapshot :: proc(world: ^Client_World, snapshot: Server_Snapshot_Packet) {
	remotes_found := 0
	
	// Update remote entities
	for i in 0..<int(snapshot.entity_count) {
		entity := snapshot.entities[i]
		
		// Skip local entity
		if entity.id == world.local_entity_id {
			// Reconcile local prediction
			state := Character_State{
				pos = entity.pos,
				vel_z = entity.vel_z,
				yaw = entity.yaw,
				pitch = entity.pitch,
				on_ground = entity.on_ground,
				active = true,
				// Phase 3: Update resources from server
				health = entity.health,
				mana = entity.mana,
				stamina = entity.stamina,
			}
			client_prediction_reconcile(&world.prediction, snapshot.tick_id, state)
			continue
		}
		
		// Update or create remote entity
		remote := &world.remote_entities[entity.id]
		if !remote.active {
			remote_entity_init(remote, entity.id)
			world.remote_count += 1
		}
		
		state := Character_State{
			pos = entity.pos,
			vel_z = entity.vel_z,
			yaw = entity.yaw,
			pitch = entity.pitch,
			on_ground = entity.on_ground,
			active = true,
			// Phase 3: Resources
			health = entity.health,
			mana = entity.mana,
			stamina = entity.stamina,
		}
		remote_entity_add_snapshot(remote, snapshot.tick_id, state)
		remotes_found += 1
	}
	
	// Phase 3: Update projectiles from snapshot
	world.projectile_count = int(snapshot.projectile_count)
	for i in 0..<int(snapshot.projectile_count) {
		world.projectiles[i] = snapshot.projectiles[i]
	}
}

// Update remote entity interpolation
client_world_update_interpolation :: proc(world: ^Client_World, interp_delay_ticks: u32) {
	for i in 0..<MAX_ENTITIES {
		remote := &world.remote_entities[i]
		if !remote.active {
			continue
		}
		remote_entity_interpolate(remote, world.client_tick, interp_delay_ticks)
	}
}

// Get statistics
client_prediction_stats :: proc(pred: ^Client_Prediction) -> (mispredict_rate: f32, total: int) {
	if pred.total_predictions == 0 {
		return 0, 0
	}
	return f32(pred.mispredict_count) / f32(pred.total_predictions), pred.total_predictions
}
