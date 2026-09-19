package main

import "core:math"
import "core:slice"

// Spiral shield-node tower authority: replaces occupancy-grid pylon damage.
//
// Each tower has:
// 1. A solid core whose height = live_node_count * STACK_STEP (derived)
// 2. An AoS of shield nodes wrapping in a spiral around the core
// 3. Nodes are the exo-shield: each has stable Node_ID, hp, max_hp, alive flag
// 4. On node destroy: remove from live set, re-sort by hp desc + stable ID tie
// 5. Spiral slot is derived from sort rank, never stored as hit target identity
// 6. Minion donate: 1 minion = 1 node at top free stack slot

// ---------------------------------------------------------------------------
// Tuning

// Hard-cap nodes per tower for MTU. Aim ~24-48 so snapshot fits in budget.
MAX_NODES_PER_TOWER :: 32

// Core vertical step per live node
STACK_STEP :: f32(0.42)

// Core is thin: just the stack column, not the full spiral base
CORE_RADIUS :: f32(0.6)

// Spiral parameters: nodes wrap around core in golden-angle spiral
SPIRAL_TURNS_PER_HEIGHT :: f32(1.8)
SPIRAL_BASE_RADIUS :: f32(2.8)
SPIRAL_RADIUS_GROWTH :: f32(0.02)  // radial growth per unit height

// Node dimensions for collision/rendering
NODE_RADIUS :: f32(0.45)
NODE_HEIGHT :: f32(0.38)

// Node HP scaling
NODE_HP_TEAM :: f32(35.0)
NODE_HP_GOLD :: f32(85.0)

// Intact fraction for rebuild trigger / centre claim
TOWER_REBUILD_FRAC :: f32(0.75)
TOWER_CLAIM_FRAC :: f32(0.80)

// ---------------------------------------------------------------------------
// Types

Node_ID :: u16

Tower_Node :: struct {
	id:      Node_ID,
	hp:      f32,
	max_hp:  f32,
	alive:   bool,
	ore:     Ore_Kind,  // for scoring on minion donation
	team:    Team_ID,   // for scoring
}

Tower :: struct {
	pylon_id:   Pylon_ID,
	base:       vec3,
	yaw:        f32,
	owner:      Team_ID,
	ore:        Ore_Kind,
	tough:      f32,

	// Node pool: fixed-size array, subset alive
	nodes:       [MAX_NODES_PER_TOWER]Tower_Node,
	live_count:  int,
	max_count:   int,  // design capacity for this tower
	next_node_id: Node_ID,

	// Sorted indices: maps rank → array index (rank 0 = highest hp node)
	// Updated on damage/death/build. Spiral position is derived from rank.
	sorted_indices: [MAX_NODES_PER_TOWER]int,

	// Derived state (not synced, computed from live_count)
	core_height: f32,
	intact:      f32,  // live_count / max_count

	// Mining state (same as old pylon)
	ore_debt:    f32,
	last_miner:  Entity_ID,
	last_bite:   vec3,
	last_bite_n: vec3,

	touched:     bool,
}

Tower_World :: struct {
	towers: [MAX_PYLONS]Tower,
	count:  int,
	dirty:  [MAX_PYLONS]bool,
}

// Global tower world (replaces g_pylons for collision authority)
g_towers: ^Tower_World

// ---------------------------------------------------------------------------
// Init / Reset

tower_world_init :: proc(world: ^Tower_World) {
	world.count = MAX_PYLONS
	for i in 0 ..< MAX_PYLONS {
		t := &world.towers[i]
		t^ = Tower{}
		t.pylon_id = Pylon_ID(i)
		t.base = pylon_base_position(i)
		t.base.z = WORLD_FLOOR_Z

		if i == 0 {
			// Golden centre
			t.owner = .None
			t.ore = .Gold
			t.tough = PYLON_TOUGHNESS_GOLD
			t.max_count = 32
		} else if i <= 3 {
			// Near-lane towers
			t.owner = team_from_index(i - 1)
			t.ore = team_ore(t.owner)
			t.tough = PYLON_TOUGHNESS_TEAM
			t.max_count = 28
		} else {
			// Far-lane towers
			t.owner = team_from_index(i - 4)
			t.ore = team_ore(t.owner)
			t.tough = PYLON_TOUGHNESS_TEAM
			t.max_count = 24
		}

		h := hash_u32(u32(i) * 2654435761 + 17)
		t.yaw = f32((h >> 16) & 0xFFFF) / f32(0x10000) * (2 * PI_F32)

		tower_build_full(t)
		world.dirty[i] = true
	}
	g_towers = world
}

tower_world_reset :: proc(world: ^Tower_World) {
	for i in 0 ..< world.count {
		t := &world.towers[i]
		tower_build_full(t)
		t.touched = false
		t.ore_debt = 0
		world.dirty[i] = true
	}
}

// Build a tower to full capacity
tower_build_full :: proc(t: ^Tower) {
	t.live_count = 0
	t.next_node_id = 1
	for i in 0 ..< t.max_count {
		node := &t.nodes[i]
		node.id = t.next_node_id
		t.next_node_id += 1
		node.hp = t.ore == .Gold ? NODE_HP_GOLD : NODE_HP_TEAM
		node.max_hp = node.hp
		node.alive = true
		node.ore = t.ore
		node.team = t.owner
		t.live_count += 1
	}
	tower_recompute(t)
	tower_resort_nodes(t)  // Critical: populate sorted_indices after building nodes
}

tower_recompute :: proc(t: ^Tower) {
	t.core_height = f32(t.live_count) * STACK_STEP
	t.intact = t.max_count > 0 ? f32(t.live_count) / f32(t.max_count) : 0
}

@(private = "file")
tower_touch :: proc(world: ^Tower_World, t: ^Tower) {
	t.touched = true
	world.dirty[t.pylon_id] = true
}

// ---------------------------------------------------------------------------
// Node positioning: spiral around core

// Given a node's sort rank (0 = highest hp), return its spiral position in local frame
tower_node_spiral_pos :: proc(rank: int, core_h: f32) -> vec3 {
	if rank < 0 {
		return {}
	}
	// Stack vertically with golden-angle spiral
	z := f32(rank) * STACK_STEP
	angle := f32(rank) * 2.39996  // golden angle
	radius := SPIRAL_BASE_RADIUS + z * SPIRAL_RADIUS_GROWTH
	return {math.cos(angle) * radius, math.sin(angle) * radius, z}
}

// Transform local to world
tower_to_world :: proc(t: ^Tower, local: vec3) -> vec3 {
	s := math.sin(t.yaw)
	c := math.cos(t.yaw)
	return t.base + vec3{c * local.x - s * local.y, s * local.x + c * local.y, local.z}
}

tower_dir_to_world :: proc(t: ^Tower, v: vec3) -> vec3 {
	s := math.sin(t.yaw)
	c := math.cos(t.yaw)
	return {c * v.x - s * v.y, s * v.x + c * v.y, v.z}
}

tower_to_local :: proc(t: ^Tower, world_pos: vec3) -> vec3 {
	d := world_pos - t.base
	s := math.sin(-t.yaw)
	c := math.cos(-t.yaw)
	return {c * d.x - s * d.y, s * d.x + c * d.y, d.z}
}

tower_dir_to_local :: proc(t: ^Tower, v: vec3) -> vec3 {
	s := math.sin(-t.yaw)
	c := math.cos(-t.yaw)
	return {c * v.x - s * v.y, s * v.x + c * v.y, v.z}
}

// ---------------------------------------------------------------------------
// Sorting: re-sort live nodes by hp desc, stable tie-break by Node_ID

Tower_Node_Sort_Key :: struct {
	hp:      f32,
	node_id: Node_ID,
	index:   int,
}

tower_resort_nodes :: proc(t: ^Tower) {
	if t.live_count <= 0 {
		return
	}

	// Gather live nodes with their array indices
	keys: [MAX_NODES_PER_TOWER]Tower_Node_Sort_Key
	n := 0
	for i in 0 ..< t.max_count {
		if t.nodes[i].alive {
			keys[n] = {hp = t.nodes[i].hp, node_id = t.nodes[i].id, index = i}
			n += 1
		}
	}

	// Sort by hp desc, then by node_id asc (stable)
	slice.sort_by(keys[:n], proc(a, b: Tower_Node_Sort_Key) -> bool {
		if a.hp != b.hp {
			return a.hp > b.hp
		}
		return a.node_id < b.node_id
	})

	// Store sorted array indices: sorted_indices[rank] = array_index
	for rank in 0 ..< n {
		t.sorted_indices[rank] = keys[rank].index
	}
	// Clear unused ranks
	for rank in n ..< MAX_NODES_PER_TOWER {
		t.sorted_indices[rank] = -1
	}
}

// Get node at given rank (0 = highest hp)
tower_node_at_rank :: proc(t: ^Tower, rank: int) -> ^Tower_Node {
	if rank < 0 || rank >= t.live_count {
		return nil
	}
	idx := t.sorted_indices[rank]
	if idx < 0 || idx >= t.max_count {
		return nil
	}
	return &t.nodes[idx]
}

// ---------------------------------------------------------------------------
// Queries

tower_get :: proc(world: ^Tower_World, id: Pylon_ID) -> ^Tower {
	if int(id) >= world.count {
		return nil
	}
	return &world.towers[id]
}

tower_standing :: proc(world: ^Tower_World, id: Pylon_ID) -> bool {
	t := tower_get(world, id)
	return t != nil && t.live_count > 0
}

tower_mineable_by :: proc(t: ^Tower, team: Team_ID) -> bool {
	if t.owner == .None {
		return true
	}
	return t.owner != team
}

// Find which node (by Node_ID) is hit at a world point (within NODE_RADIUS)
// Returns the node and its current spiral rank
tower_node_at_point :: proc(t: ^Tower, wp: vec3, pad: f32) -> (node_id: Node_ID, rank: int, ok: bool) {
	local := tower_to_local(t, wp)
	reach2 := (NODE_RADIUS + pad) * (NODE_RADIUS + pad)

	// Check live nodes in sorted rank order
	for rank in 0 ..< t.live_count {
		node := tower_node_at_rank(t, rank)
		if node == nil || !node.alive {
			continue
		}
		pos := tower_node_spiral_pos(rank, t.core_height)
		dx := local.x - pos.x
		dy := local.y - pos.y
		dz := local.z - pos.z
		if dx * dx + dy * dy + dz * dz <= reach2 {
			return node.id, rank, true
		}
	}
	return 0, -1, false
}

// Does the tower (core or nodes) block this world point?
tower_blocks_point :: proc(world: ^Tower_World, wp: vec3, pad: f32) -> bool {
	for i in 0 ..< world.count {
		t := &world.towers[i]
		if t.live_count == 0 {
			continue
		}
		// Cylinder reject
		dx := wp.x - t.base.x
		dy := wp.y - t.base.y
		max_r := SPIRAL_BASE_RADIUS + t.core_height * SPIRAL_RADIUS_GROWTH + NODE_RADIUS + pad
		if dx * dx + dy * dy > max_r * max_r {
			continue
		}
		if wp.z < t.base.z - pad || wp.z > t.base.z + t.core_height + NODE_HEIGHT + pad {
			continue
		}

		local := tower_to_local(t, wp)
		
		// Check core (thin cylinder)
		if local.z >= 0 && local.z <= t.core_height {
			if local.x * local.x + local.y * local.y <= CORE_RADIUS * CORE_RADIUS {
				return true
			}
		}

		// Check nodes
		if _, _, hit := tower_node_at_point(t, wp, pad); hit {
			return true
		}
	}
	return false
}

// Raycast: nearest tower along ray
tower_raycast :: proc(world: ^Tower_World, ro, rd: vec3, max_t: f32) -> (t: f32, id: Pylon_ID, node_id: Node_ID, hit: bool) {
	best := max_t
	found_tower := -1
	found_node := Node_ID(0)
	
	for i in 0 ..< world.count {
		tw := &world.towers[i]
		if tw.live_count == 0 {
			continue
		}

		// Transform ray to local
		local_ro := tower_to_local(tw, ro)
		local_rd := tower_dir_to_local(tw, rd)

		// Bound cylinder
		max_r := SPIRAL_BASE_RADIUS + tw.core_height * SPIRAL_RADIUS_GROWTH + NODE_RADIUS
		z0 := f32(-NODE_RADIUS)
		z1 := tw.core_height + NODE_HEIGHT

		// Clip ray to bound
		t0, t1, clip_hit := tower_bound_clip(local_ro, local_rd, z0, z1, max_r, best)
		if !clip_hit {
			continue
		}

		// March and check core + nodes
		steps := int((t1 - t0) / (NODE_RADIUS * 0.5)) + 1
		steps = clamp_int(steps, 1, 128)
		step_size := (t1 - t0) / f32(steps)

		for step in 0 ..< steps {
			t_sample := t0 + f32(step) * step_size
			if t_sample >= best {
				break
			}
			p := local_ro + local_rd * t_sample

			// Core hit?
			if p.z >= 0 && p.z <= tw.core_height {
				if p.x * p.x + p.y * p.y <= CORE_RADIUS * CORE_RADIUS {
					if t_sample < best {
						best = t_sample
						found_tower = i
						found_node = 0
					}
					break
				}
			}

			// Node hit?
			wp := tower_to_world(tw, p)
			if nid, _, node_hit := tower_node_at_point(tw, wp, 0); node_hit {
				if t_sample < best {
					best = t_sample
					found_tower = i
					found_node = nid
				}
				break
			}
		}
	}

	if found_tower < 0 {
		return 0, 0, 0, false
	}
	return best, Pylon_ID(found_tower), found_node, true
}

tower_bound_clip :: proc(ro, rd: vec3, z0, z1, radius: f32, max_t: f32) -> (t0, t1: f32, hit: bool) {
	enter := f32(0)
	exit := max_t

	// Z slab
	if abs(rd.z) < 1e-6 {
		if ro.z < z0 || ro.z > z1 {
			return 0, 0, false
		}
	} else {
		inv := 1 / rd.z
		a := (z0 - ro.z) * inv
		b := (z1 - ro.z) * inv
		if a > b {
			a, b = b, a
		}
		enter = max(enter, a)
		exit = min(exit, b)
	}

	// Cylinder
	qa := rd.x * rd.x + rd.y * rd.y
	qc := ro.x * ro.x + ro.y * ro.y - radius * radius
	if qa < 1e-12 {
		if qc > 0 {
			return 0, 0, false
		}
	} else {
		qb := ro.x * rd.x + ro.y * rd.y
		disc := qb * qb - qa * qc
		if disc < 0 {
			return 0, 0, false
		}
		root := math.sqrt(disc)
		enter = max(enter, (-qb - root) / qa)
		exit = min(exit, (-qb + root) / qa)
	}

	if enter > exit {
		return 0, 0, false
	}
	return max(enter, 0), exit, true
}

// Normal at world point (approximate from nearest node or core surface)
tower_normal_world :: proc(world: ^Tower_World, id: Pylon_ID, wp: vec3) -> vec3 {
	t := tower_get(world, id)
	if t == nil {
		return {0, 0, 1}
	}
	local := tower_to_local(t, wp)
	
	// Check core (thin cylinder)
	if local.z >= 0 && local.z <= t.core_height {
		if local.x * local.x + local.y * local.y <= CORE_RADIUS * CORE_RADIUS {
			// Core: radial normal
			n := norm_vec3(vec3{local.x, local.y, 0})
			return tower_dir_to_world(t, n)
		}
	}

	// Node: approximate radial
	_, rank, ok := tower_node_at_point(t, wp, NODE_RADIUS)
	if ok {
		pos := tower_node_spiral_pos(rank, t.core_height)
		d := local - pos
		if len2_vec3(d) > 0.01 {
			return tower_dir_to_world(t, norm_vec3(d))
		}
	}

	return {0, 0, 1}
}

// Top of tower for minion rebuild landing
tower_column_top_world :: proc(world: ^Tower_World, id: Pylon_ID, wp: vec3) -> (pos: vec3, ok: bool) {
	t := tower_get(world, id)
	if t == nil {
		return {}, false
	}
	// Land on core top
	local := tower_to_local(t, wp)
	local.z = t.core_height
	return tower_to_world(t, local), true
}

tower_at_point :: proc(world: ^Tower_World, wp: vec3, pad: f32) -> (id: Pylon_ID, ok: bool) {
	for i in 0 ..< world.count {
		t := &world.towers[i]
		if t.live_count == 0 {
			continue
		}
		dx := wp.x - t.base.x
		dy := wp.y - t.base.y
		max_r := SPIRAL_BASE_RADIUS + t.core_height * SPIRAL_RADIUS_GROWTH + NODE_RADIUS + pad
		if dx * dx + dy * dy > max_r * max_r {
			continue
		}
		if wp.z < t.base.z - pad || wp.z > t.base.z + t.core_height + NODE_HEIGHT + pad {
			continue
		}

		local := tower_to_local(t, wp)
		
		// Core?
		if local.z >= 0 && local.z <= t.core_height {
			if local.x * local.x + local.y * local.y <= CORE_RADIUS * CORE_RADIUS {
				return Pylon_ID(i), true
			}
		}

		// Node?
		if _, _, hit := tower_node_at_point(t, wp, pad); hit {
			return Pylon_ID(i), true
		}
	}
	return 0, false
}

// ---------------------------------------------------------------------------
// Mining: damage a node

tower_mine :: proc(
	world:  ^Tower_World,
	id:     Pylon_ID,
	at:     vec3,
	radius: f32,
	amount: f32,
	miner:  Entity_ID,
	team:   Team_ID,
) -> (ore: f32, ok: bool) {
	t := tower_get(world, id)
	if t == nil || t.live_count == 0 {
		return 0, false
	}
	if !tower_mineable_by(t, team) {
		return 0, false
	}

	local := tower_to_local(t, at)
	damage := amount / max(t.tough, 0.01)
	reach2 := max(radius, NODE_RADIUS * 1.2) * max(radius, NODE_RADIUS * 1.2)
	removed := 0
	killed := 0

	// Damage nodes in splash radius (iterate by sorted rank)
	for rank in 0 ..< t.live_count {
		node := tower_node_at_rank(t, rank)
		if node == nil || !node.alive {
			continue
		}
		pos := tower_node_spiral_pos(rank, t.core_height)
		dx := local.x - pos.x
		dy := local.y - pos.y
		dz := local.z - pos.z
		if dx * dx + dy * dy + dz * dz > reach2 {
			continue
		}

		before := node.hp
		node.hp -= damage
		if node.hp < 0 {
			node.hp = 0
		}
		removed += int(before - node.hp)

		if node.hp <= 0 && node.alive {
			node.alive = false
			t.live_count -= 1
			killed += 1
		}
	}

	if removed == 0 {
		return 0, false
	}

	// Re-sort after damage
	if killed > 0 {
		tower_resort_nodes(t)
	}

	t.last_miner = miner
	t.last_bite = local
	t.last_bite_n = {0, 0, 1}  // approximate
	tower_recompute(t)
	tower_touch(world, t)

	// Ore yield: scale by nodes killed
	ore = f32(killed) * ORE_PER_VOXEL * 4.0  // rough equiv to old voxel
	return ore, true
}

// Build: add one node (minion donation)
tower_build :: proc(world: ^Tower_World, id: Pylon_ID, at: vec3, radius: f32, amount: f32) -> (gained: int, ok: bool) {
	t := tower_get(world, id)
	if t == nil {
		return 0, false
	}
	if t.live_count >= t.max_count {
		return 0, false
	}

	// Find first dead node slot
	for i in 0 ..< t.max_count {
		node := &t.nodes[i]
		if node.alive {
			continue
		}
		// Resurrect node
		node.id = t.next_node_id
		t.next_node_id += 1
		node.hp = t.ore == .Gold ? NODE_HP_GOLD : NODE_HP_TEAM
		node.max_hp = node.hp
		node.alive = true
		node.ore = t.ore
		node.team = t.owner
		t.live_count += 1
		tower_recompute(t)
		tower_resort_nodes(t)
		tower_touch(world, t)
		return 1, true
	}

	return 0, false
}

// Build point for minion landing
tower_build_point :: proc(world: ^Tower_World, id: Pylon_ID, turn: int) -> vec3 {
	t := tower_get(world, id)
	if t == nil {
		return {}
	}
	// Land on top of core
	z := t.core_height
	a := f32(turn) * 2.39996
	r := CORE_RADIUS * 0.8
	return {math.cos(a) * r, math.sin(a) * r, z}
}

tower_credit_ore :: proc(world: ^Tower_World, id: Pylon_ID, ore: f32) {
	t := tower_get(world, id)
	if t == nil {
		return
	}
	t.ore_debt += ore
}

tower_reserve :: proc(world: ^Tower_World, id: Pylon_ID) -> f32 {
	t := tower_get(world, id)
	if t == nil {
		return 0
	}
	return f32(t.live_count) * ORE_PER_VOXEL * 4.0
}

// ---------------------------------------------------------------------------
// Wire: pack/unpack for replication

// Pack: quantize node hp to u8 (0-255 range)
tower_pack_nodes :: proc(t: ^Tower, dst: []u8) -> int {
	if len(dst) < t.max_count {
		return 0
	}
	n := 0
	for i in 0 ..< t.max_count {
		node := &t.nodes[i]
		if !node.alive {
			dst[n] = 0
			n += 1
			continue
		}
		q := u8(clampf(node.hp / node.max_hp * 255, 0, 255))
		dst[n] = q
		n += 1
	}
	return n
}

tower_unpack_nodes :: proc(t: ^Tower, src: []u8) {
	if len(src) < t.max_count {
		return
	}
	t.live_count = 0
	for i in 0 ..< t.max_count {
		node := &t.nodes[i]
		q := src[i]
		if q == 0 {
			node.alive = false
			node.hp = 0
			continue
		}
		node.alive = true
		node.hp = f32(q) / 255.0 * node.max_hp
		t.live_count += 1
	}
	tower_recompute(t)
	tower_resort_nodes(t)
}

tower_collect_dirty :: proc(world: ^Tower_World, dst: []Pylon_ID) -> int {
	n := 0
	for i in 0 ..< world.count {
		if !world.dirty[i] {
			continue
		}
		if n >= len(dst) {
			break
		}
		dst[n] = Pylon_ID(i)
		n += 1
	}
	return n
}

tower_clear_dirty :: proc(world: ^Tower_World, ids: []Pylon_ID) {
	for id in ids {
		if int(id) < world.count {
			world.dirty[id] = false
		}
	}
}

// ---------------------------------------------------------------------------
// Tick: ore chunk payouts

tower_world_tick :: proc(world: ^Tower_World, chunks: ^Ore_Chunk_World, dt: f32) {
	_ = dt
	for i in 0 ..< world.count {
		t := &world.towers[i]
		if !t.touched {
			continue
		}
		for t.ore_debt >= ORE_PER_CHUNK {
			t.ore_debt -= ORE_PER_CHUNK
			// Spawn chunk at tower base
			local := t.last_bite
			if len2_vec3(local) < 0.01 {
				local = {SPIRAL_BASE_RADIUS, 0, t.core_height * 0.5}
			}
			wp := tower_to_world(t, local)
			ore_chunk_spawn_loose(chunks, t.ore, wp + vec3{0, 0, 0.5}, ORE_PER_CHUNK)
		}
	}
}
