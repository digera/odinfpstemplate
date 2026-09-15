package main

import "core:fmt"

// Entity system using numeric IDs and #soa arrays for data-oriented design.
// MMO-ready: 64-bit world positions with local float offsets (not yet implemented).

Entity_ID :: u32
INVALID_ENTITY :: Entity_ID(0)
MAX_ENTITIES :: 64

// Character state for networked entities
Character_State :: struct {
	pos:       vec3,  // World position (meters) - TODO: split into 64-bit grid + local offset
	vel_z:     f32,   // Vertical velocity
	yaw:       f32,   // Horizontal look angle
	pitch:     f32,   // Vertical look angle  
	on_ground: bool,  // Ground contact flag
	active:    bool,  // Entity slot is in use
	
	// Phase 3: Resource pools
	health:    f32,   // Current health
	mana:      f32,   // Current mana
	stamina:   f32,   // Current stamina
	
	// Death/respawn (playtesting)
	dead:           bool,  // Entity is dead (no capture contribution, awaiting respawn)
	respawn_timer:  f32,   // Time until respawn (seconds)
}

// Input state for one entity for one tick
Input_State :: struct {
	move_fwd:   f32,  // Forward/back [-1, 1]
	move_str:   f32,  // Strafe left/right [-1, 1]
	jump:       bool, // Jump input
	delta_yaw:  f32,  // Yaw change this tick
	delta_pitch: f32, // Pitch change this tick
	
	// Phase 3: Spell casting
	cast_spell: Spell_ID,  // Spell button pressed (0 = none)
}

// Entity world - data-oriented storage
Entity_World :: struct {
	// Parallel arrays indexed by entity ID
	characters: #soa[MAX_ENTITIES]Character_State,
	inputs:     [MAX_ENTITIES]Input_State,
	spell_states: [MAX_ENTITIES]Entity_Spell_State,  // Phase 3: cooldowns, buffs
	teams:      [MAX_ENTITIES]Team_ID,               // Phase 4: team assignments
	next_id:    Entity_ID,
	count:      int,
}

entity_world_init :: proc() -> Entity_World {
	world := Entity_World{}
	world.next_id = 1 // 0 is INVALID_ENTITY
	return world
}

entity_spawn :: proc(world: ^Entity_World, pos: vec3, team := Team_ID.None) -> Entity_ID {
	if world.count >= MAX_ENTITIES {
		return INVALID_ENTITY
	}
	
	// Find first free slot
	for i in 1..<MAX_ENTITIES {
		if !world.characters[i].active {
			id := Entity_ID(i)
			world.characters[i] = Character_State{
				pos = pos,
				yaw = 0,
				pitch = 0,
				on_ground = false,
				active = true,
				// Phase 3: Initialize resources
				health = HEALTH_MAX,
				mana = MANA_MAX,
				stamina = STAMINA_MAX,
			}
			world.inputs[i] = {}
			world.spell_states[i] = {}
			world.teams[i] = team  // Phase 4: team assignment
			world.count += 1
			return id
		}
	}
	
	return INVALID_ENTITY
}

entity_destroy :: proc(world: ^Entity_World, id: Entity_ID) {
	if id == INVALID_ENTITY || id >= MAX_ENTITIES {
		return
	}
	if world.characters[id].active {
		world.characters[id].active = false
		world.count -= 1
	}
}

// Get character by ID (returns copy for reading, use set_character to update)
entity_get_character :: proc(world: ^Entity_World, id: Entity_ID) -> (Character_State, bool) {
	if id == INVALID_ENTITY || id >= MAX_ENTITIES {
		return {}, false
	}
	if !world.characters[id].active {
		return {}, false
	}
	return world.characters[id], true
}

// Get mutable reference to character (for inline updates)
entity_get_character_mut :: proc(world: ^Entity_World, id: Entity_ID) -> (idx: int, ok: bool) {
	if id == INVALID_ENTITY || id >= MAX_ENTITIES {
		return 0, false
	}
	if !world.characters[int(id)].active {
		return 0, false
	}
	return int(id), true
}

entity_set_input :: proc(world: ^Entity_World, id: Entity_ID, input: Input_State) {
	if id == INVALID_ENTITY || id >= MAX_ENTITIES {
		return
	}
	world.inputs[id] = input
}

// Get entity team
entity_get_team :: proc(world: ^Entity_World, id: Entity_ID) -> Team_ID {
	if id == INVALID_ENTITY || id >= MAX_ENTITIES {
		return .None
	}
	return world.teams[id]
}

// Set entity team
entity_set_team :: proc(world: ^Entity_World, id: Entity_ID, team: Team_ID) {
	if id == INVALID_ENTITY || id >= MAX_ENTITIES {
		return
	}
	world.teams[id] = team
}
