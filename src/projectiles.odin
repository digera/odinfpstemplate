package main

import "core:math"
import "core:fmt"

// Projectile system - Phase 3 combat
// Lightweight SOA storage for server-authoritative projectiles

MAX_PROJECTILES :: 256

Projectile_ID :: u32

// Projectile state
Projectile :: struct {
	active:     bool,
	id:         Projectile_ID,
	spell_id:   Spell_ID,
	owner_id:   Entity_ID,      // Who cast it
	
	pos:        vec3,
	vel:        vec3,            // Velocity (m/s)
	
	lifetime:   f32,             // Remaining lifetime (sec)
	radius:     f32,             // Collision radius
	
	damage:     f32,
	aoe_radius: f32,
	knockback:  f32,
	slow_factor: f32,
	slow_duration: f32,
}

// Projectile world (SOA for cache efficiency)
Projectile_World :: struct {
	projectiles: #soa[MAX_PROJECTILES]Projectile,
	count:       int,
	next_id:     Projectile_ID,
}

projectile_world_init :: proc() -> Projectile_World {
	return Projectile_World{
		next_id = 1,
	}
}

// Spawn projectile
projectile_spawn :: proc(world: ^Projectile_World, spell_cast: ^Spell_Cast, def: ^Spell_Def) -> Projectile_ID {
	if world.count >= MAX_PROJECTILES {
		return 0  // Failed
	}
	
	// Find free slot
	for i in 0..<MAX_PROJECTILES {
		if !world.projectiles[i].active {
			id := world.next_id
			world.next_id += 1
			world.count += 1
			
			world.projectiles[i] = Projectile{
				active = true,
				id = id,
				spell_id = spell_cast.spell_id,
				owner_id = spell_cast.caster_id,
				pos = spell_cast.origin,
				vel = spell_cast.direction * def.proj_speed,
				lifetime = def.proj_lifetime,
				radius = def.proj_radius,
				damage = def.damage,
				aoe_radius = def.aoe_radius,
				knockback = def.knockback,
				slow_factor = def.slow_factor,
				slow_duration = def.slow_duration,
			}
			
			return id
		}
	}
	
	return 0
}

// Destroy projectile
projectile_destroy :: proc(world: ^Projectile_World, slot: int) {
	if slot < 0 || slot >= MAX_PROJECTILES {
		return
	}
	if world.projectiles[slot].active {
		world.projectiles[slot].active = false
		world.count -= 1
	}
}

// Update all projectiles
projectile_tick :: proc(world: ^Projectile_World, entity_world: ^Entity_World, dt: f32) {
	GRAVITY :: vec3{0, 0, -9.8}
	
	for i in 0..<MAX_PROJECTILES {
		if !world.projectiles[i].active {
			continue
		}
		
		proj := &world.projectiles[i]
		
		// Update lifetime
		proj.lifetime -= dt
		if proj.lifetime <= 0 {
			projectile_destroy(world, i)
			continue
		}
		
		// Apply gravity if needed
		def := &SPELL_DEFS[proj.spell_id]
		if def.proj_gravity {
			proj.vel += GRAVITY * dt
		}
		
		// Integrate position
		new_pos := proj.pos + proj.vel * dt
		
		// Check collision with entities
		hit := false
		for entity_idx in 1..<MAX_ENTITIES {
			if !entity_world.characters[entity_idx].active {
				continue
			}
			
			// Skip owner (can't hit self)
			if Entity_ID(entity_idx) == proj.owner_id {
				continue
			}
			
			entity_pos := entity_world.characters[entity_idx].pos
			
			// Cylinder collision (projectile sphere vs entity cylinder)
			dx := new_pos.x - entity_pos.x
			dy := new_pos.y - entity_pos.y
			dz := new_pos.z - entity_pos.z
			
			// Check horizontal distance
			dist_horiz := math.sqrt(dx*dx + dy*dy)
			if dist_horiz > (proj.radius + CHARACTER_RADIUS_M) {
				continue
			}
			
			// Check vertical bounds
			if dz < 0 || dz > CHARACTER_HEIGHT_M {
				continue
			}
			
			// Phase 4: No friendly fire (check teams)
			owner_team := entity_get_team(entity_world, proj.owner_id)
			target_team := entity_get_team(entity_world, Entity_ID(entity_idx))
			
			if !teams_are_enemies(owner_team, target_team) {
				continue  // Skip friendly targets
			}
			
			// Hit!
			hit = true
			
			fmt.printf("[Combat] Projectile hit! Owner %d → Entity %d: %.1f damage (%.1f→%.1f HP)\n",
				proj.owner_id, Entity_ID(entity_idx), proj.damage,
				entity_world.characters[entity_idx].health, entity_world.characters[entity_idx].health - proj.damage)
			
			// Apply damage
			entity_world.characters[entity_idx].health -= proj.damage
			
			// Apply AoE if applicable (exclude primary target to avoid double-dip)
			if proj.aoe_radius > 0 {
				fmt.printf("[Combat] AoE explosion at (%.1f, %.1f, %.1f) radius %.1fm\n",
					new_pos.x, new_pos.y, new_pos.z, proj.aoe_radius)
				projectile_apply_aoe(world, entity_world, i, new_pos, Entity_ID(entity_idx))  // Pass primary target
			}
			
			// Apply knockback
			if proj.knockback > 0 {
				// knockback_dir := norm_vec3(vec3{dx, dy, 0})
				// Note: knockback would be applied to velocity, but we don't have that in Character_State yet
				// TODO: Add velocity to Character_State or apply impulse in movement system
			}
			
			projectile_destroy(world, i)
			break
		}
		
		if !hit {
			// Check room bounds
			if !room_inside(new_pos, proj.radius) {
				projectile_destroy(world, i)
				continue
			}
			
			// Update position
			proj.pos = new_pos
		}
	}
}

// Apply AoE damage (exclude primary_target to avoid double-dip)
projectile_apply_aoe :: proc(proj_world: ^Projectile_World, entity_world: ^Entity_World, proj_slot: int, center: vec3, primary_target: Entity_ID) {
	proj := &proj_world.projectiles[proj_slot]
	
	for entity_idx in 1..<MAX_ENTITIES {
		if !entity_world.characters[entity_idx].active {
			continue
		}
		
		if Entity_ID(entity_idx) == proj.owner_id {
			continue  // Skip owner
		}
		
		if Entity_ID(entity_idx) == primary_target {
			continue  // Skip primary target (already took full damage)
		}
		
		entity_pos := entity_world.characters[entity_idx].pos
		
		// Check distance
		dx := entity_pos.x - center.x
		dy := entity_pos.y - center.y
		dz := entity_pos.z - center.z
		dist := math.sqrt(dx*dx + dy*dy + dz*dz)
		
		if dist <= proj.aoe_radius {
			// Phase 4: No friendly fire (check teams)
			owner_team := entity_get_team(entity_world, proj.owner_id)
			target_team := entity_get_team(entity_world, Entity_ID(entity_idx))
			
			if teams_are_enemies(owner_team, target_team) {
				// Apply damage (half damage for AoE to avoid double-hit on primary target)
				entity_world.characters[entity_idx].health -= proj.damage * 0.5
			}
		}
	}
}
