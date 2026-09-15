package main

// Lag compensation - Phase 3
// Rewind entity hitboxes for server-authoritative hit registration

HISTORY_SIZE :: 128  // ~2 seconds at 60Hz

// Entity history for one entity
Entity_History :: struct {
	positions: [HISTORY_SIZE]vec3,
	ticks:     [HISTORY_SIZE]u32,
	write_idx: int,
	count:     int,
}

// Lag compensation state
Lag_Comp_State :: struct {
	entity_histories: [MAX_ENTITIES]Entity_History,
}

lag_comp_init :: proc() -> Lag_Comp_State {
	return Lag_Comp_State{}
}

// Record entity position for this tick
lag_comp_record :: proc(state: ^Lag_Comp_State, entity_id: Entity_ID, pos: vec3, tick: u32) {
	if entity_id >= MAX_ENTITIES {
		return
	}
	
	history := &state.entity_histories[entity_id]
	
	history.positions[history.write_idx] = pos
	history.ticks[history.write_idx] = tick
	history.write_idx = (history.write_idx + 1) % HISTORY_SIZE
	
	if history.count < HISTORY_SIZE {
		history.count += 1
	}
}

// Get entity position at specific tick (linear interpolation if between ticks)
lag_comp_get_position :: proc(state: ^Lag_Comp_State, entity_id: Entity_ID, tick: u32) -> (pos: vec3, found: bool) {
	if entity_id >= MAX_ENTITIES {
		return {}, false
	}
	
	history := &state.entity_histories[entity_id]
	if history.count == 0 {
		return {}, false
	}
	
	// Find closest tick <= target tick
	best_idx := -1
	best_tick := u32(0)
	
	for i in 0..<history.count {
		idx := (history.write_idx - 1 - i + HISTORY_SIZE) % HISTORY_SIZE
		if history.ticks[idx] <= tick && (best_idx == -1 || history.ticks[idx] > best_tick) {
			best_idx = idx
			best_tick = history.ticks[idx]
		}
	}
	
	if best_idx == -1 {
		return {}, false
	}
	
	// Exact match
	if best_tick == tick {
		return history.positions[best_idx], true
	}
	
	// Try to interpolate with next tick
	next_idx := (best_idx + 1) % HISTORY_SIZE
	if history.ticks[next_idx] > tick && history.ticks[next_idx] < tick + 10 {  // Within reasonable range
		// Linear interpolation
		t := f32(tick - best_tick) / f32(history.ticks[next_idx] - best_tick)
		pos = lerpv3(history.positions[best_idx], history.positions[next_idx], t)
		return pos, true
	}
	
	// Return closest
	return history.positions[best_idx], true
}

// Hitscan raycast with lag compensation
hitscan_check :: proc(
	lag_comp: ^Lag_Comp_State,
	entity_world: ^Entity_World,
	caster_id: Entity_ID,
	origin: vec3,
	direction: vec3,
	max_range: f32,
	client_tick: u32,
) -> (hit: bool, hit_entity: Entity_ID, hit_pos: vec3) {
	
	closest_dist := max_range
	hit_entity = INVALID_ENTITY
	
	for entity_idx in 1..<MAX_ENTITIES {
		if !entity_world.characters[entity_idx].active {
			continue
		}
		
		if Entity_ID(entity_idx) == caster_id {
			continue  // Skip self
		}
		
		// B4: Check for friendly fire (skip same-team targets)
		caster_team := entity_get_team(entity_world, caster_id)
		target_team := entity_get_team(entity_world, Entity_ID(entity_idx))
		if !teams_are_enemies(caster_team, target_team) {
			continue
		}
		
		// Get entity position at client's view tick (lag compensation)
		entity_pos, found := lag_comp_get_position(lag_comp, Entity_ID(entity_idx), client_tick)
		if !found {
			// Fallback to current position if no history
			entity_pos = entity_world.characters[entity_idx].pos
		}
		
		// Ray vs cylinder intersection
		// Cylinder: center at entity_pos, radius CHARACTER_RADIUS_M, height CHARACTER_HEIGHT_M
		
		// Project ray origin onto cylinder axis (Z)
		ray_start_2d := vec3{origin.x, origin.y, 0}
		ray_dir_2d := vec3{direction.x, direction.y, 0}
		cyl_center_2d := vec3{entity_pos.x, entity_pos.y, 0}
		
		// Closest point on ray to cylinder axis in 2D
		to_cyl := cyl_center_2d - ray_start_2d
		proj_len := dot_vec3(to_cyl, ray_dir_2d)
		
		if proj_len < 0 || proj_len > max_range {
			continue  // Behind ray or beyond range
		}
		
		closest_point_2d := ray_start_2d + ray_dir_2d * proj_len
		dist_to_axis := length_vec3(closest_point_2d - cyl_center_2d)
		
		if dist_to_axis > CHARACTER_RADIUS_M {
			continue  // Missed horizontally
		}
		
		// Check vertical bounds
		hit_z := origin.z + direction.z * proj_len
		if hit_z < entity_pos.z || hit_z > entity_pos.z + CHARACTER_HEIGHT_M {
			continue  // Missed vertically
		}
		
		// Hit! Check if closest
		if proj_len < closest_dist {
			closest_dist = proj_len
			hit_entity = Entity_ID(entity_idx)
			hit_pos = origin + direction * proj_len
		}
	}
	
	if hit_entity != INVALID_ENTITY {
		return true, hit_entity, hit_pos
	}
	
	return false, INVALID_ENTITY, {}
}
