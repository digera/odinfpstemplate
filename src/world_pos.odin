// Phase 5: World Position Types
// 64-bit integer world coordinates + local float offsets
package main

import "core:math"

// World position: 64-bit integer chunk coordinate + local float offset
// Allows for massive worlds without float precision loss
World_Pos :: struct {
	chunk_x:   i64,    // Chunk coordinate X (each chunk = CHUNK_SIZE meters)
	chunk_y:   i64,    // Chunk coordinate Y
	chunk_z:   i64,    // Chunk coordinate Z
	local_x:   f32,    // Local offset within chunk [0, CHUNK_SIZE)
	local_y:   f32,
	local_z:   f32,
}

// Chunk size in meters (world coordinates)
CHUNK_SIZE :: 256.0

// Convert vec3 to World_Pos (for arena → world migration)
world_pos_from_vec3 :: proc(v: vec3) -> World_Pos {
	wp: World_Pos
	
	// Floor division to get chunk coordinate
	wp.chunk_x = i64(math.floor(v.x / CHUNK_SIZE))
	wp.chunk_y = i64(math.floor(v.y / CHUNK_SIZE))
	wp.chunk_z = i64(math.floor(v.z / CHUNK_SIZE))
	
	// Remainder is local offset
	wp.local_x = v.x - f32(wp.chunk_x) * CHUNK_SIZE
	wp.local_y = v.y - f32(wp.chunk_y) * CHUNK_SIZE
	wp.local_z = v.z - f32(wp.chunk_z) * CHUNK_SIZE
	
	return wp
}

// Convert World_Pos to vec3 (for rendering/physics in local chunk)
world_pos_to_vec3 :: proc(wp: World_Pos) -> vec3 {
	return vec3{
		f32(wp.chunk_x) * CHUNK_SIZE + wp.local_x,
		f32(wp.chunk_y) * CHUNK_SIZE + wp.local_y,
		f32(wp.chunk_z) * CHUNK_SIZE + wp.local_z,
	}
}

// Get vec3 relative to a reference World_Pos (for rendering entities relative to camera)
world_pos_relative :: proc(pos: World_Pos, ref: World_Pos) -> vec3 {
	dx := f32(pos.chunk_x - ref.chunk_x) * CHUNK_SIZE + (pos.local_x - ref.local_x)
	dy := f32(pos.chunk_y - ref.chunk_y) * CHUNK_SIZE + (pos.local_y - ref.local_y)
	dz := f32(pos.chunk_z - ref.chunk_z) * CHUNK_SIZE + (pos.local_z - ref.local_z)
	return vec3{dx, dy, dz}
}

// Check if two World_Pos are in the same chunk
world_pos_same_chunk :: proc(a: World_Pos, b: World_Pos) -> bool {
	return a.chunk_x == b.chunk_x && a.chunk_y == b.chunk_y && a.chunk_z == b.chunk_z
}

// Chunk ID for spatial queries
Chunk_ID :: struct {
	x: i64,
	y: i64,
	z: i64,
}

chunk_id_from_world_pos :: proc(wp: World_Pos) -> Chunk_ID {
	return Chunk_ID{wp.chunk_x, wp.chunk_y, wp.chunk_z}
}

chunk_id_eq :: proc(a, b: Chunk_ID) -> bool {
	return a.x == b.x && a.y == b.y && a.z == b.z
}
