package main

import "core:fmt"
import "core:time"

// Match state machine for Phase 4: Nexus Dominion
//
// Match flow: Waiting → Active → Ended
// Win condition: First team to 1000 essence or time limit

Match_State :: enum u8 {
	Waiting,   // Waiting for players / warmup
	Active,    // Match in progress
	Ended,     // Match completed, display results
}

Match_Result :: enum u8 {
	None,           // Match ongoing
	Alpha_Wins,     // Team Alpha reached 1000 essence
	Beta_Wins,      // Team Beta reached 1000 essence
	Draw,           // Time limit reached with tie
}

Match :: struct {
	state:           Match_State,
	result:          Match_Result,
	
	// Essence scoring
	alpha_essence:   f32,      // Team Alpha essence points
	beta_essence:    f32,      // Team Beta essence points
	
	// Timing
	match_time:      f32,      // Seconds elapsed since match start
	match_duration:  f32,      // Max match duration (seconds), 0 = no limit
	
	// Round tracking
	round_number:    int,
	rounds_played:   int,
}

// Configuration
ESSENCE_WIN_THRESHOLD :: f32(1000.0)   // Essence needed to trigger Nexus Collapse
DEFAULT_MATCH_DURATION :: f32(15 * 60) // 15 minutes (900 seconds)
WARMUP_DURATION :: f32(5.0)            // Warmup time in Waiting state

// Test configuration (can be overridden via environment or build flag)
test_essence_threshold := ESSENCE_WIN_THRESHOLD
test_essence_multiplier := f32(1.0)  // Multiply essence gain for fast testing

// Configure test mode for faster matches (call from server init)
match_configure_test_mode :: proc(win_threshold: f32, essence_multiplier: f32) {
	test_essence_threshold = win_threshold
	test_essence_multiplier = essence_multiplier
	fmt.printf("[Match] Test mode configured: Win at %.0f essence, %.1fx generation rate\n", 
		test_essence_threshold, test_essence_multiplier)
}

match_init :: proc() -> Match {
	return Match{
		state = .Waiting,
		result = .None,
		alpha_essence = 0,
		beta_essence = 0,
		match_time = 0,
		match_duration = DEFAULT_MATCH_DURATION,
		round_number = 1,
	}
}

// Update match state for one tick
match_tick :: proc(match: ^Match, obelisk_world: ^Obelisk_World, dt: f32) {
	#partial switch match.state {
	case .Waiting:
		// Auto-start after warmup (or when enough players join)
		match.match_time += dt
		if match.match_time >= WARMUP_DURATION {
			match_start(match)
		}
		
	case .Active:
		match.match_time += dt
		
		// Generate essence from held Obelisks
		match_generate_essence(match, obelisk_world, dt)
		
		// Check win conditions
		if match.alpha_essence >= test_essence_threshold {
			match_end(match, .Alpha_Wins)
		} else if match.beta_essence >= test_essence_threshold {
			match_end(match, .Beta_Wins)
		} else if match.match_duration > 0 && match.match_time >= match.match_duration {
			// Time limit reached
			if match.alpha_essence > match.beta_essence {
				match_end(match, .Alpha_Wins)
			} else if match.beta_essence > match.alpha_essence {
				match_end(match, .Beta_Wins)
			} else {
				match_end(match, .Draw)
			}
		}
		
	case .Ended:
		// Match over, wait for restart or return to lobby
		// (Restart logic handled externally)
	}
}

// Generate essence from held Obelisks
match_generate_essence :: proc(match: ^Match, obelisk_world: ^Obelisk_World, dt: f32) {
	for i in 0..<obelisk_world.count {
		obelisk := &obelisk_world.obelisks[i]
		
		if obelisk.state == .Held {
			essence_gain := ESSENCE_PER_SEC * dt * test_essence_multiplier
			
			switch obelisk.owner {
			case .Alpha:
				match.alpha_essence += essence_gain
			case .Beta:
				match.beta_essence += essence_gain
			case .None:
				// Should not happen
			}
		}
	}
}

// Start match
match_start :: proc(match: ^Match) {
	match.state = .Active
	match.match_time = 0
	match.alpha_essence = 0
	match.beta_essence = 0
	match.result = .None
	
	fmt.printf("[Match] Match started! (Win threshold: %.0f essence)\n", test_essence_threshold)
}

// End match with result
match_end :: proc(match: ^Match, result: Match_Result) {
	match.state = .Ended
	match.result = result
	match.rounds_played += 1
	
	winner := ""
	switch result {
	case .Alpha_Wins:
		winner = "Team ALPHA"
	case .Beta_Wins:
		winner = "Team BETA"
	case .Draw:
		winner = "DRAW"
	case .None:
		winner = "NONE"
	}
	
	fmt.printf("[Match] Match ended! Winner: %s (%.0f vs %.0f essence)\n", 
		winner, match.alpha_essence, match.beta_essence)
}

// Reset match for new round
match_reset :: proc(match: ^Match) {
	match.state = .Waiting
	match.result = .None
	match.alpha_essence = 0
	match.beta_essence = 0
	match.match_time = 0
	match.round_number += 1
	
	fmt.printf("[Match] Starting round %d\n", match.round_number)
}

// Get match info string for HUD
match_info_string :: proc(match: ^Match) -> string {
	#partial switch match.state {
	case .Waiting:
		return "WARMUP"
	case .Active:
		return "ACTIVE"
	case .Ended:
		switch match.result {
		case .Alpha_Wins:  return "ALPHA WINS"
		case .Beta_Wins:   return "BETA WINS"
		case .Draw:        return "DRAW"
		case .None:        return "ENDED"
		}
	}
	return "UNKNOWN"
}
