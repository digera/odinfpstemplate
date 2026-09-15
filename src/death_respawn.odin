// Death and respawn system (minimal for playtesting)
package main

import "core:fmt"
import "core:time"

RESPAWN_DELAY_SEC :: f32(3.0)  // Respawn after 3 seconds

// Check for death and handle respawn
entity_tick_death_respawn :: proc(entity_world: ^Entity_World, dt: f32) {
	for i in 0..<MAX_ENTITIES {
		char := &entity_world.characters[i]
		if !char.active {
			continue
		}
		
		// Check for death
		if char.health <= 0 && !char.dead {
			// Mark as dead
			char.dead = true
			char.respawn_timer = RESPAWN_DELAY_SEC
			fmt.printf("[Death] Entity %d died, respawning in %.1fs\n", i, RESPAWN_DELAY_SEC)
		}
		
		// Handle respawn timer
		if char.dead {
			char.respawn_timer -= dt
			
			if char.respawn_timer <= 0 {
				// Respawn at team spawn
				team := entity_world.teams[i]
				spawn_pos := get_team_spawn_position(team)
				
				char.pos = spawn_pos
				char.vel_z = 0
				char.health = HEALTH_MAX
				char.mana = MANA_MAX
				char.stamina = STAMINA_MAX
				char.dead = false
				char.respawn_timer = 0
				
				fmt.printf("[Respawn] Entity %d respawned at team spawn\n", i)
			}
		}
	}
}

// Get team spawn position (reuse from server init)
get_team_spawn_position :: proc(team: Team_ID) -> vec3 {
	center := (ROOM_MIN + ROOM_MAX) * 0.5
	
	if team == .Alpha {
		// Alpha spawns south
		return vec3{center.x, center.y - 4.5, ROOM_MIN.z}
	} else if team == .Beta {
		// Beta spawns north
		return vec3{center.x, center.y + 4.5, ROOM_MIN.z}
	} else {
		// Neutral/fallback: center
		return vec3{center.x, center.y, ROOM_MIN.z}
	}
}
