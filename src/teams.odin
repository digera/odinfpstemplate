package main

// Team system for Phase 4: Nexus Dominion

Team_ID :: enum u8 {
	None = 0,
	Alpha = 1,  // Team A (Red)
	Beta = 2,   // Team B (Blue)
}

TEAM_ALPHA_COLOR :: vec3{0.92, 0.32, 0.28}  // Red
TEAM_BETA_COLOR :: vec3{0.42, 0.62, 0.92}   // Blue

// Get team name for display
team_name :: proc(team: Team_ID) -> string {
	switch team {
	case .Alpha: return "ALPHA"
	case .Beta:  return "BETA"
	case .None:  return "NONE"
	}
	return "NONE"
}

// Get team color
team_color :: proc(team: Team_ID) -> vec3 {
	switch team {
	case .Alpha: return TEAM_ALPHA_COLOR
	case .Beta:  return TEAM_BETA_COLOR
	case .None:  return {0.6, 0.6, 0.6}
	}
	return {0.6, 0.6, 0.6}
}

// Check if teams are enemies (no friendly fire by default)
teams_are_enemies :: proc(a, b: Team_ID) -> bool {
	if a == .None || b == .None {
		return true  // No team = hostile to all
	}
	return a != b
}
