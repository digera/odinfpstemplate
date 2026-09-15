// Phase 5: Spatial Grid
// Abstract spatial index for entity queries (arena = single chunk, MMO = sparse multi-chunk)
package main

import "core:fmt"
import "core:slice"
import "core:math"

// Spatial grid mode
Spatial_Grid_Mode :: enum {
	Single_Chunk,   // Arena mode: all entities in one chunk (current)
	Multi_Chunk,    // MMO mode: sparse chunk loading (future)
}

// Spatial grid for entity lookups
Spatial_Grid :: struct {
	mode:            Spatial_Grid_Mode,
	arena_chunk_id:  Chunk_ID,  // For single-chunk mode
	// Future: sparse map of Chunk_ID → entity lists
}

// Initialize spatial grid (single chunk for arena)
spatial_grid_init :: proc(mode: Spatial_Grid_Mode) -> Spatial_Grid {
	grid := Spatial_Grid{
		mode = mode,
		arena_chunk_id = Chunk_ID{0, 0, 0},  // Arena is always at origin chunk
	}
	
	when ODIN_DEBUG {
		fmt.printf("[SpatialGrid] Initialized in %v mode\n", mode)
	}
	
	return grid
}

// Query entities in radius (arena mode: check all entities; MMO mode: check nearby chunks)
spatial_grid_query_radius :: proc(
	grid: ^Spatial_Grid,
	entity_world: ^Entity_World,
	center: vec3,
	radius: f32,
	allocator := context.allocator,
) -> []Entity_ID {
	// Arena mode: simple radius check against all entities
	// (This is what we've been doing implicitly; now it's explicit)
	
	results := make([dynamic]Entity_ID, allocator)
	radius_sq := radius * radius
	
	for idx in 0..<MAX_ENTITIES {
		char := entity_world.characters[idx]
		if !char.active {
			continue
		}
		
		dx := char.pos.x - center.x
		dy := char.pos.y - center.y
		dz := char.pos.z - center.z
		dist_sq := dx*dx + dy*dy + dz*dz
		
		if dist_sq <= radius_sq {
			append(&results, Entity_ID(idx))
		}
	}
	
	return results[:]
}

// Raycast against entities (for hitscan spells)
spatial_grid_raycast :: proc(
	grid: ^Spatial_Grid,
	entity_world: ^Entity_World,
	origin: vec3,
	dir: vec3,
	max_distance: f32,
) -> (hit: bool, entity_id: Entity_ID, hit_pos: vec3) {
	// Arena mode: check all entities
	// (Lag compensation already does this; this makes it explicit)
	
	closest_t := max_distance
	hit = false
	
	entity_radius := f32(0.3)  // Character radius approximation
	
	for idx in 0..<MAX_ENTITIES {
		char := entity_world.characters[idx]
		if !char.active {
			continue
		}
		
		// Simple sphere raycast (entity is a cylinder, but sphere is close enough)
		entity_center := char.pos
		entity_center.z += 1.0  // Approximate center height
		
		// Ray-sphere intersection
		oc := vec3{origin.x - entity_center.x, origin.y - entity_center.y, origin.z - entity_center.z}
		a := dir.x*dir.x + dir.y*dir.y + dir.z*dir.z
		b := 2.0 * (oc.x*dir.x + oc.y*dir.y + oc.z*dir.z)
		c := (oc.x*oc.x + oc.y*oc.y + oc.z*oc.z) - (entity_radius * entity_radius)
		
		discriminant := b*b - 4*a*c
		if discriminant >= 0 {
			t := (-b - math.sqrt(discriminant)) / (2*a)
			if t > 0 && t < closest_t {
				closest_t = t
				hit = true
				entity_id = Entity_ID(idx)
				hit_pos = vec3{
					origin.x + dir.x * t,
					origin.y + dir.y * t,
					origin.z + dir.z * t,
				}
			}
		}
	}
	
	return
}

// Get chunk ID for a world position (for future multi-chunk)
spatial_grid_get_chunk :: proc(grid: ^Spatial_Grid, wp: World_Pos) -> Chunk_ID {
	return chunk_id_from_world_pos(wp)
}

// Check if chunk is loaded (arena mode: always true for chunk 0; MMO mode: check loaded set)
spatial_grid_is_chunk_loaded :: proc(grid: ^Spatial_Grid, chunk_id: Chunk_ID) -> bool {
	switch grid.mode {
	case .Single_Chunk:
		return chunk_id_eq(chunk_id, grid.arena_chunk_id)
	case .Multi_Chunk:
		// Future: check loaded chunk set
		return false
	}
	return false
}
