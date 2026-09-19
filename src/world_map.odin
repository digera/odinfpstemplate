package main

import "core:math"
import "base:runtime"

// Nexus Arena map: three team bases connected by straight lanes to an open
// octagonal center. The walkable volume is the union of yaw-rotated boxes
// ("floor boxes"); solid cover ("solid boxes") is subtracted from it.
//
// The same data drives server collision, bot navigation and the client's
// analytic ray tracer, so everything here must stay deterministic and cheap.

World_Box :: struct {
	center: vec3,
	half:   vec3,
	yaw:    f32,
}

WORLD_FLOOR_Z         :: f32(0)
WORLD_CEIL_Z          :: f32(14)      // top face of walkable volume = sky (wall height)
WORLD_PLAZA_HALF      :: f32(32)      // center plaza (doubled from 16)
WORLD_LANE_R0         :: f32(28)      // lane starts (overlaps plaza, doubled from 14)
WORLD_LANE_R1         :: f32(100)     // lane ends (overlaps base)
WORLD_LANE_HALF_W     :: f32(4.5)
WORLD_BASE_R          :: f32(110)
WORLD_BASE_HALF       :: f32(11)
WORLD_SPAWN_R         :: f32(114)
WORLD_LANE_PYLON_R  :: f32(40)      // near-lane pylon (pushed from 24 to 40)
WORLD_LANE_PYLON_FAR_R :: f32(70)   // far-lane pylon
WORLD_EXTENT          :: f32(125)     // rough outer radius (fog / culling)

NUM_FLOOR_BOXES :: 11
NUM_SOLID_BOXES :: 15  // 3 plaza pillars + 12 lane crates (4 per lane)

world_floor_boxes: [NUM_FLOOR_BOXES]World_Box
world_solid_boxes: [NUM_SOLID_BOXES]World_Box

// Direction each team's lane leaves the center. Alpha north, then every 120°.
team_angle :: proc(team: Team_ID) -> f32 {
	idx := team_index(team)
	if idx < 0 {
		return 0
	}
	return f32(math.PI) * 0.5 + f32(idx) * (2.0 * f32(math.PI) / f32(TEAM_COUNT))
}

team_dir :: proc(team: Team_ID) -> vec3 {
	a := team_angle(team)
	return {math.cos(a), math.sin(a), 0}
}

@(init)
world_map_init :: proc "contextless" () {
	context = runtime.default_context()
	half_z := (WORLD_CEIL_Z - WORLD_FLOOR_Z) * 0.5
	cz := WORLD_FLOOR_Z + half_z
	n := 0

	// Center plaza: two squares rotated 45° = octagon.
	world_floor_boxes[n] = {center = {0, 0, cz}, half = {WORLD_PLAZA_HALF, WORLD_PLAZA_HALF, half_z}, yaw = 0}; n += 1
	world_floor_boxes[n] = {center = {0, 0, cz}, half = {WORLD_PLAZA_HALF, WORLD_PLAZA_HALF, half_z}, yaw = f32(math.PI) * 0.25}; n += 1

	for team in TEAMS {
		a := team_angle(team)
		d := team_dir(team)

		// Lane
		lane_mid := (WORLD_LANE_R0 + WORLD_LANE_R1) * 0.5
		lane_half := (WORLD_LANE_R1 - WORLD_LANE_R0) * 0.5
		world_floor_boxes[n] = {
			center = d * lane_mid + vec3{0, 0, cz},
			half   = {lane_half, WORLD_LANE_HALF_W, half_z},
			yaw    = a,
		}; n += 1

		// Base octagon
		bc := d * WORLD_BASE_R + vec3{0, 0, cz}
		world_floor_boxes[n] = {center = bc, half = {WORLD_BASE_HALF, WORLD_BASE_HALF, half_z}, yaw = a}; n += 1
		world_floor_boxes[n] = {center = bc, half = {WORLD_BASE_HALF, WORLD_BASE_HALF, half_z}, yaw = a + f32(math.PI) * 0.25}; n += 1
	}
	// n == NUM_FLOOR_BOXES (2 plaza + 3 * (1 lane + 2 base))

	s := 0
	// Plaza pillars, sitting between lanes.
	for team in TEAMS {
		a := team_angle(team) + f32(math.PI) / 3.0
		p := vec3{math.cos(a), math.sin(a), 0} * 18.0
		world_solid_boxes[s] = {center = p + vec3{0, 0, 2.6}, half = {1.1, 1.1, 2.6}, yaw = a}; s += 1
	}
	// Lane cover: four staggered crates per lane on the extended lanes.
	for team in TEAMS {
		a := team_angle(team)
		d := team_dir(team)
		side := vec3{-d.y, d.x, 0}
		world_solid_boxes[s] = {center = d * 35.0 + side * 2.0 + vec3{0, 0, 1.15}, half = {1.0, 0.9, 1.15}, yaw = a}; s += 1
		world_solid_boxes[s] = {center = d * 48.0 - side * 2.0 + vec3{0, 0, 1.15}, half = {1.0, 0.9, 1.15}, yaw = a}; s += 1
		world_solid_boxes[s] = {center = d * 65.0 + side * 2.2 + vec3{0, 0, 1.15}, half = {1.0, 0.9, 1.15}, yaw = a}; s += 1
		world_solid_boxes[s] = {center = d * 85.0 - side * 2.2 + vec3{0, 0, 1.15}, half = {1.0, 0.9, 1.15}, yaw = a}; s += 1
	}
	// s == NUM_SOLID_BOXES (3 pillars + 3 * 4 crates)
}

// Transform a world point into a box's local frame.
box_local :: proc(b: ^World_Box, p: vec3) -> vec3 {
	d := p - b.center
	s := math.sin(b.yaw)
	c := math.cos(b.yaw)
	return {c * d.x + s * d.y, -s * d.x + c * d.y, d.z}
}

// Transform a direction out of a box's local frame back into world space.
box_unrot :: proc(b: ^World_Box, v: vec3) -> vec3 {
	s := math.sin(b.yaw)
	c := math.cos(b.yaw)
	return {c * v.x - s * v.y, s * v.x + c * v.y, v.z}
}

// grow > 0 expands the box (solids), grow < 0 shrinks it (floors).
// Z is tested loosely so a foot resting exactly on the floor counts as inside.
box_contains :: proc(b: ^World_Box, p: vec3, grow: f32) -> bool {
	l := box_local(b, p)
	if abs(l.x) > b.half.x + grow || abs(l.y) > b.half.y + grow {
		return false
	}
	return l.z >= -b.half.z - 0.05 && l.z <= b.half.z + grow
}

// A point is free if it lies inside the walkable union (shrunk by pad), outside
// every solid box (grown by pad), and not inside standing ore.
//
// Routing pylons through here is deliberate. Everything that asks the world
// whether a point is solid comes through this one proc -- movement, projectile
// sweeps, `world_segment_clear` for line of sight, `world_ray_hit` for beam
// reach -- so a tower becomes cover, stops spells and blocks sight in one move
// instead of four. `pylon_blocks_point` rejects on a bound cylinder first, so a
// point nowhere near a tower costs seven distance compares and no occupancy.
world_point_free :: proc(p: vec3, pad: f32) -> bool {
	in_floor := false
	for i in 0..<NUM_FLOOR_BOXES {
		if box_contains(&world_floor_boxes[i], p, -pad) {
			in_floor = true
			break
		}
	}
	if !in_floor {
		return false
	}
	for i in 0..<NUM_SOLID_BOXES {
		if box_contains(&world_solid_boxes[i], p, pad) {
			return false
		}
	}
	if g_towers != nil && tower_blocks_point(g_towers, p, pad) {
		return false
	}
	return true
}

// Per-axis distance by which `p` sticks out of a floor box's walkable slab
// (negative = still inside). Mirrors box_contains(b, p, -pad), including its
// loose lower Z bound.
@(private = "file")
box_exit_depth :: proc(b: ^World_Box, p: vec3, pad: f32) -> vec3 {
	l := box_local(b, p)
	return {
		abs(l.x) - (b.half.x - pad),
		abs(l.y) - (b.half.y - pad),
		max(l.z - (b.half.z - pad), (-b.half.z - 0.05) - l.z),
	}
}

// Outward normal of the surface something just ran into: `from` is the last
// point that passed world_point_free, `blocked` the first one that didn't.
world_surface_normal :: proc(from, blocked: vec3, pad: f32) -> vec3 {
	// Ore first, from the occupied cell face, so a spell that glances off a
	// tower leaves along the rock it actually hit.
	if g_towers != nil {
		if id, ok := tower_at_point(g_towers, blocked, pad); ok {
			return tower_normal_world(g_towers, id, blocked)
		}
	}

	// Solid cover: leave through the face we are least deep into.
	for i in 0..<NUM_SOLID_BOXES {
		b := &world_solid_boxes[i]
		if !box_contains(b, blocked, pad) {
			continue
		}
		l := box_local(b, blocked)
		depth := vec3{
			(b.half.x + pad) - abs(l.x),
			(b.half.y + pad) - abs(l.y),
			(b.half.z + pad) - abs(l.z),
		}
		axis := 0
		for k in 1..<3 {
			if depth[k] < depth[axis] {
				axis = k
			}
		}
		n := vec3{}
		n[axis] = l[axis] >= 0 ? 1 : -1
		return box_unrot(b, n)
	}

	// Otherwise we left the walkable union. Of the boxes we were still inside,
	// use the one `blocked` only just escaped: in an overlap region (a lane
	// mouth, say) that is the corridor whose wall we actually hit.
	best := -1
	best_axis := 0
	best_exit := f32(1e9)
	for i in 0..<NUM_FLOOR_BOXES {
		b := &world_floor_boxes[i]
		if !box_contains(b, from, -pad) {
			continue
		}
		exit := box_exit_depth(b, blocked, pad)
		axis := 0
		for k in 1..<3 {
			if exit[k] > exit[axis] {
				axis = k
			}
		}
		if exit[axis] < best_exit {
			best_exit = exit[axis]
			best_axis = axis
			best = i
		}
	}
	if best >= 0 {
		b := &world_floor_boxes[best]
		l := box_local(b, blocked)
		n := vec3{}
		// Point back inside: for Z that means down off the ceiling or up off
		// the floor, for X/Y in from the wall we crossed.
		n[best_axis] = l[best_axis] >= 0 ? -1 : 1
		return box_unrot(b, n)
	}

	// Degenerate (started inside geometry): send it back the way it came.
	d := from - blocked
	if len2_vec3(d) < 1e-8 {
		return {0, 0, 1}
	}
	return norm_vec3(d)
}

// Segment visibility test by sampling. Good enough for bot line-of-sight.
world_segment_clear :: proc(a, b: vec3, step: f32 = 0.6) -> bool {
	d := b - a
	l := len_vec3(d)
	if l < 1e-4 {
		return true
	}
	n := int(l / step) + 1
	for i in 1..<n {
		t := f32(i) / f32(n)
		if !world_point_free(a + d * t, 0.05) {
			return false
		}
	}
	return true
}

// How far a ray gets before it meets a wall, the floor, the ceiling or cover:
// `max_dist` if nothing stops it. Marches in `step`s and then bisects the last
// one, so the answer is stable to a centimetre or so without the march being
// that fine. `dir` must be unit length. Shared by hitscan on the server and
// by the client drawing its own beam.
world_ray_hit :: proc(origin, dir: vec3, max_dist: f32, step: f32 = 0.25) -> f32 {
	free := f32(0)
	blocked := max_dist
	found := false
	for t := step; t < max_dist; t += step {
		if !world_point_free(origin + dir * t, 0.05) {
			blocked = t
			found = true
			break
		}
		free = t
	}
	if !found {
		if world_point_free(origin + dir * max_dist, 0.05) {
			return max_dist
		}
		free = max(free, max_dist - step)
	}
	for _ in 0..<5 {
		mid := (free + blocked) * 0.5
		if world_point_free(origin + dir * mid, 0.05) {
			free = mid
		} else {
			blocked = mid
		}
	}
	return blocked
}

// Spawn point inside a team base. Slots fan out laterally then backwards.
team_spawn_position :: proc(team: Team_ID, slot: int) -> vec3 {
	if team == .None || team == .Spectator {
		return {0, 0, WORLD_FLOOR_Z}
	}
	d := team_dir(team)
	side := vec3{-d.y, d.x, 0}
	lateral := f32((slot % 5) - 2) * 2.2
	back := f32((slot / 5) % 3) * 2.2
	p := d * (WORLD_SPAWN_R + back) + side * lateral
	p.z = WORLD_FLOOR_Z
	return p
}

// Pylon placement: one in center, then near/far pairs for each lane.
// Layout: [0] center, [1-3] near-lane (Alpha/Beta/Gamma), [4-6] far-lane (Alpha/Beta/Gamma)
pylon_base_position :: proc(index: int) -> vec3 {
	if index == 0 {
		return {0, 0, WORLD_FLOOR_Z}
	}
	if index >= 1 && index <= 3 {
		team := team_from_index(index - 1)
		p := team_dir(team) * WORLD_LANE_PYLON_R
		p.z = WORLD_FLOOR_Z
		return p
	}
	if index >= 4 && index <= 6 {
		team := team_from_index(index - 4)
		p := team_dir(team) * WORLD_LANE_PYLON_FAR_R
		p.z = WORLD_FLOOR_Z
		return p
	}
	return {0, 0, WORLD_FLOOR_Z}
}

// ---- Navigation helpers -------------------------------------------------

World_Region_Kind :: enum u8 {
	Plaza,
	Lane,
	Base,
}

World_Region :: struct {
	kind: World_Region_Kind,
	team: Team_ID, // corridor owner for Lane/Base
}

// Which corridor a point belongs to (by angle) and how far out it is.
world_region :: proc(p: vec3) -> World_Region {
	r := math.sqrt(p.x * p.x + p.y * p.y)
	if r < WORLD_LANE_R0 + 1.0 {
		return {kind = .Plaza, team = .None}
	}
	ang := math.atan2(p.y, p.x)
	best := Team_ID.Alpha
	best_diff := f32(99)
	for team in TEAMS {
		diff := abs(wrap_angle(ang - team_angle(team)))
		if diff < best_diff {
			best_diff = diff
			best = team
		}
	}
	if r < WORLD_LANE_R1 - 1.0 {
		return {kind = .Lane, team = best}
	}
	return {kind = .Base, team = best}
}

// Next waypoint to walk toward to reach `to` from `from` through the lane graph.
nav_next_waypoint :: proc(from, to: vec3) -> vec3 {
	rf := world_region(from)
	rt := world_region(to)

	// Same corridor (or both in the plaza): the map is convex there, walk straight.
	if rf.kind == .Plaza && rt.kind == .Plaza {
		return to
	}
	if rf.kind != .Plaza && rt.kind != .Plaza && rf.team == rt.team {
		return to
	}
	if rf.kind == .Plaza {
		// Head for the mouth of the target lane.
		mouth := team_dir(rt.team) * (WORLD_LANE_R0 + 5.0)
		mouth.z = to.z
		// If already lined up with the lane, go direct.
		d := to - from
		dist := len_vec3(d)
		if dist > 0.01 {
			mdir := norm_vec3(mouth - from)
			if dot_vec3(norm_vec3(d), mdir) > 0.985 {
				return to
			}
		}
		return mouth
	}
	// In someone's lane or base, target elsewhere: go to the plaza first.
	return {0, 0, to.z}
}

wrap_angle :: proc(a: f32) -> f32 {
	x := a
	for x > f32(math.PI) {
		x -= 2.0 * f32(math.PI)
	}
	for x < -f32(math.PI) {
		x += 2.0 * f32(math.PI)
	}
	return x
}
