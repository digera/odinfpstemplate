package main

import "core:fmt"

// Nexus Obelisk capture point system for Phase 4: Nexus Dominion
//
// Three Obelisks positioned symmetrically in the arena.
// Holding Obelisks generates essence for your team.
// First team to 1000 essence triggers Nexus Collapse (match end).

Obelisk_ID :: u8
MAX_OBELISKS :: 3

Obelisk_State :: enum u8 {
	Neutral,      // No team controls
	Contested,    // Multiple teams in capture volume
	Capturing,    // One team is capturing (progress bar)
	Held,         // Fully captured by a team
}

Obelisk :: struct {
	id:              Obelisk_ID,
	pos:             vec3,           // World position
	radius:          f32,            // Capture volume radius
	state:           Obelisk_State,
	owner:           Team_ID,        // Current owner (None if neutral/contested)
	capturing_team:  Team_ID,        // Team currently capturing
	capture_progress: f32,           // 0.0 to 1.0 (seconds to capture)
	
	// Presence tracking
	alpha_count:     int,            // Number of Team Alpha players in volume
	beta_count:      int,            // Number of Team Beta players in volume
}

Obelisk_World :: struct {
	obelisks: [MAX_OBELISKS]Obelisk,
	count:    int,
}

// Configuration
CAPTURE_TIME :: f32(5.0)          // Seconds to fully capture from neutral
ESSENCE_PER_SEC :: f32(10.0)      // Essence generated per second per held Obelisk
OBELISK_RADIUS :: f32(3.0)        // Capture volume radius in meters
OBELISK_HEIGHT :: f32(4.0)        // Visual height (for rendering)

obelisk_world_init :: proc() -> Obelisk_World {
	world := Obelisk_World{}
	
	// Position three Obelisks symmetrically in arena
	// Arena is 16x16 meters, center at (8, 8)
	// Place in triangle formation
	
	center := (ROOM_MIN + ROOM_MAX) * 0.5
	
	// Center Obelisk (neutral spawn)
	world.obelisks[0] = Obelisk{
		id = 0,
		pos = vec3{center.x, center.y, ROOM_MIN.z},  // Floor level
		radius = OBELISK_RADIUS,
		state = .Neutral,
		owner = .None,
	}
	
	// Alpha-side Obelisk (south)
	world.obelisks[1] = Obelisk{
		id = 1,
		pos = vec3{center.x - 4.5, center.y - 4.5, ROOM_MIN.z},
		radius = OBELISK_RADIUS,
		state = .Neutral,
		owner = .None,
	}
	
	// Beta-side Obelisk (north)
	world.obelisks[2] = Obelisk{
		id = 2,
		pos = vec3{center.x + 4.5, center.y + 4.5, ROOM_MIN.z},
		radius = OBELISK_RADIUS,
		state = .Neutral,
		owner = .None,
	}
	
	world.count = MAX_OBELISKS
	
	fmt.println("[Obelisk] Initialized 3 capture points")
	return world
}

// Check if position is within Obelisk capture volume
obelisk_contains :: proc(obelisk: ^Obelisk, pos: vec3) -> bool {
	dx := pos.x - obelisk.pos.x
	dy := pos.y - obelisk.pos.y
	dz := pos.z - obelisk.pos.z
	dist_sq := dx*dx + dy*dy
	
	// Capture volume is cylinder (ignore Z for simplicity)
	return dist_sq <= obelisk.radius * obelisk.radius && dz >= 0 && dz <= OBELISK_HEIGHT
}

// Update Obelisk state for one tick (dt = 1/60 second)
obelisk_tick :: proc(world: ^Obelisk_World, entity_world: ^Entity_World, dt: f32) {
	// For each Obelisk, count players in capture volume
	for i in 0..<world.count {
		obelisk := &world.obelisks[i]
		
		// Reset presence counters
		obelisk.alpha_count = 0
		obelisk.beta_count = 0
		
		// Count players in volume (check all active entities with teams)
		for eid in 1..<MAX_ENTITIES {
			if !entity_world.characters[eid].active {
				continue
			}
			
			char := entity_world.characters[eid]
			
			// Ignore dead players (no capture contribution)
			if char.dead {
				continue
			}
			
			team := entity_get_team(entity_world, Entity_ID(eid))
			
			if obelisk_contains(obelisk, char.pos) {
				switch team {
				case .Alpha:
					obelisk.alpha_count += 1
				case .Beta:
					obelisk.beta_count += 1
				case .None:
					// Neutral entities don't affect capture
				}
			}
		}
		
		// Update state based on presence
		obelisk_update_state(obelisk, dt)
	}
}

// Update single Obelisk state machine
obelisk_update_state :: proc(obelisk: ^Obelisk, dt: f32) {
	alpha_present := obelisk.alpha_count > 0
	beta_present := obelisk.beta_count > 0
	
	// Both teams present = contested
	if alpha_present && beta_present {
		if obelisk.state != .Contested {
			obelisk.state = .Contested
			obelisk.capturing_team = .None
			obelisk.capture_progress = 0
		}
		return
	}
	
	// No one present
	if !alpha_present && !beta_present {
		// If capturing, decay progress
		if obelisk.state == .Capturing {
			obelisk.capture_progress -= dt / CAPTURE_TIME * 0.5  // Decay at half speed
			if obelisk.capture_progress <= 0 {
				obelisk.capture_progress = 0
				obelisk.state = obelisk.owner == .None ? .Neutral : .Held
				obelisk.capturing_team = .None
			}
		}
		return
	}
	
	// One team present
	capturing_team := alpha_present ? Team_ID.Alpha : Team_ID.Beta
	
	// If already held by this team, stay held
	if obelisk.state == .Held && obelisk.owner == capturing_team {
		return
	}
	
	// Start or continue capturing
	if obelisk.state != .Capturing || obelisk.capturing_team != capturing_team {
		// Start new capture
		obelisk.state = .Capturing
		obelisk.capturing_team = capturing_team
		obelisk.capture_progress = 0
	}
	
	// Advance capture progress
	obelisk.capture_progress += dt / CAPTURE_TIME
	
	// Capture complete
	if obelisk.capture_progress >= 1.0 {
		obelisk.state = .Held
		obelisk.owner = capturing_team
		obelisk.capturing_team = .None
		obelisk.capture_progress = 1.0
		
		fmt.printf("[Obelisk %d] Captured by Team %s\n", obelisk.id, team_name(capturing_team))
	}
}

// Get Obelisk by ID
obelisk_get :: proc(world: ^Obelisk_World, id: Obelisk_ID) -> ^Obelisk {
	if int(id) >= world.count {
		return nil
	}
	return &world.obelisks[id]
}
