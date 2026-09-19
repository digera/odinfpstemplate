package main

// Graphical client: connection state machine, fixed-step prediction with
// render interpolation, input, and hand-off to the renderer.

import "core:fmt"
import "core:math"
import "core:os"
import "base:runtime"
import sapp "sokol:app"
import slog "sokol:log"

HELLO_INTERVAL   :: f32(0.5)
JOIN_INTERVAL    :: f32(0.4)
LOBBY_REFRESH    :: f32(1.0)
CONNECTION_LOSS_SEC :: f64(5.0)

Game_Client :: struct {
	network:        Network_Client,
	phase:          Client_Phase,
	client_world:   Client_World,
	renderer:       Client_Renderer,
	fx:             Camera_FX,

	// Look (client-authoritative, never overwritten by the server)
	view_yaw:       f32,
	view_pitch:     f32,

	// Movement input carried between frames
	move_input:     Input_State,
	selected_slot:  int,              // index into HOTBAR

	// Fixed-step accumulator
	sim_accum:      f32,
	render_alpha:   f32,

	// Redundant input history (newest first)
	input_history:  [INPUT_REDUNDANCY]Input_State,
	history_count:  int,

	// Lobby
	lobby:          Server_Lobby_Packet,
	have_lobby:     bool,
	chosen_team:    Team_ID,
	hello_timer:    f32,
	join_timer:     f32,
	reject_timer:   f32,
	reject_reason:  Lobby_Reject,
	last_packet_time: f64,

	// Name entry on the team-select screen. Number keys are both letters and
	// team picks, so the field has to be explicitly finished: while
	// `name_editing` is set, typing goes into the name and nothing joins.
	player_name:    Player_Name,
	name_editing:   bool,

	// Local cooldown mirror (server is authoritative; this drives the HUD)
	cooldowns:      [Spell_ID]f32,
	cast_pulse:     f32,
	last_cast:      Spell_ID,
	charging_spell:   Spell_ID,
	charge_accum:     f32,
	charge_committed: bool, // button came up; keep winding until a full-power fire

	// Menu state
	menu_selected:  int, // selected menu item (0-based)
	is_spectating:  bool, // spectator mode

	// Aim lock is latched rather than re-tested every frame: it takes a
	// healthy bar to engage but runs until the bar is dry, so a lock does not
	// chatter on and off while stamina hovers around the threshold.
	aim_locked:     bool,
}

game_client: Game_Client

client_init :: proc "c" () {
	context = runtime.default_context()
	fmt.println("=== Nexus Arena Client ===")

	server_host := DEFAULT_SERVER_HOST
	ip_buf: [256]u8
	if env_ip := os.get_env_buf(ip_buf[:], "SERVER_IP"); env_ip != "" {
		server_host = env_ip
	}
	if !network_client_init(&game_client.network, server_host, server_port_from_env()) {
		fmt.eprintln("Failed to initialize network client")
		return
	}

	loss_buf: [64]u8
	if v := os.get_env_buf(loss_buf[:], "NEXUS_SIM_LOSS"); v != "" {
		network_client_sim_loss(&game_client.network, 0.05)
	}

	client_world_init(&game_client.client_world)
	game_client.phase = .Connecting
	game_client.name_editing = true
	game_client.selected_slot = 0
	game_client.last_packet_time = 0
	camera_fx_init(&game_client.fx)

	client_renderer_init(&game_client.renderer)
	client_audio_init()
	fmt.println("Client initialized, looking for server...")
}

client_frame :: proc "c" () {
	context = runtime.default_context()

	gc := &game_client
	dt := f32(clamp(sapp.frame_duration(), 0.0, 0.1))
	gc.client_world.local_time += f64(dt)

	client_poll_network(gc)

	switch gc.phase {
	case .Connecting:
		client_release_mouse()
		gc.hello_timer -= dt
		if gc.hello_timer <= 0 {
			network_client_send_hello(&gc.network)
			gc.hello_timer = HELLO_INTERVAL
		}

	case .Team_Select:
		client_release_mouse()
		gc.hello_timer -= dt
		if gc.hello_timer <= 0 {
			network_client_send_hello(&gc.network)
			gc.hello_timer = LOBBY_REFRESH
		}
		gc.reject_timer = max(gc.reject_timer - dt, 0)
		client_edit_name(gc)
		if !gc.name_editing {
			for slot in 1..=TEAM_COUNT {
				if input_consume_slot(slot) {
					team := team_from_index(slot - 1)
					if client_team_allowed(gc, team) {
						gc.chosen_team = team
						network_client_send_join(&gc.network, team, gc.player_name)
						gc.join_timer = JOIN_INTERVAL
						gc.phase = .Joining
					} else {
						gc.reject_reason = .Team_Most_Populated
						gc.reject_timer = 2.0
					}
				}
			}
		}
		for slot in 1..=HOTBAR_SLOTS {
			_ = input_consume_slot(slot)
		}
		_ = input_consume_click()

	case .Joining:
		client_release_mouse()
		gc.join_timer -= dt
		if gc.join_timer <= 0 {
			network_client_send_join(&gc.network, gc.chosen_team, gc.player_name)
			gc.join_timer = JOIN_INTERVAL
		}
		// Swallow anything typed while we wait, so it does not land in the
		// name field or a hotbar slot once we are in.
		_ = input_consume_text()
		_ = input_consume_enter()
		_ = input_consume_backspace()
		for slot in 1..=HOTBAR_SLOTS {
			_ = input_consume_slot(slot)
		}

	case .Playing, .In_Menu:
		if gc.client_world.local_time - gc.last_packet_time > CONNECTION_LOSS_SEC {
			fmt.println("[Client] Connection lost, returning to lobby")
			client_reset_to_lobby(gc)
			break
		}
		if gc.phase == .In_Menu {
			client_release_mouse()
			client_handle_menu_input(gc)
		} else {
			client_handle_input(gc, dt)
			client_step_simulation(gc, dt)
		}
	}

	client_audio_update(gc, dt)
	client_world_update(&gc.client_world, dt)
	client_update_target(gc)
	camera_fx_update(&gc.fx, gc, dt)

	for spell in Spell_ID {
		gc.cooldowns[spell] = max(gc.cooldowns[spell] - dt, 0)
	}
	gc.cast_pulse = max(gc.cast_pulse - dt * 3.5, 0)

	client_renderer_draw(&gc.renderer, gc)
}

client_cleanup :: proc "c" () {
	context = runtime.default_context()
	network_client_shutdown(&game_client.network)
	client_renderer_shutdown(&game_client.renderer)
	client_audio_shutdown()

	rate, total := client_prediction_stats(&game_client.client_world.prediction)
	fmt.printf("[Client] Prediction: %d ticks, %.1f%% corrected\n", total, rate * 100)
	sent, recv, _ := network_client_stats(&game_client.network)
	fmt.printf("[Client] Network: %d sent, %d recv\n", sent, recv)
}

// ---------------------------------------------------------------------------

@(private = "file")
client_release_mouse :: proc() {
	if sapp.mouse_locked() {
		sapp.lock_mouse(false)
	}
	_, _ = input_consume_look()
}

// The name field on the team-select screen. Enter toggles it: on to type, off
// to pick a team. Without that the digits in "Zog2" would join Tide halfway
// through the word.
@(private = "file")
client_edit_name :: proc(gc: ^Game_Client) {
	typed := input_consume_text()
	rubout := input_consume_backspace()
	if input_consume_enter() {
		gc.name_editing = !gc.name_editing
	}
	if !gc.name_editing {
		return
	}
	for c in typed {
		if gc.player_name.len >= MAX_PLAYER_NAME_LEN {
			break
		}
		gc.player_name.text[gc.player_name.len] = c
		gc.player_name.len += 1
	}
	if rubout && gc.player_name.len > 0 {
		gc.player_name.len -= 1
	}
}

client_team_allowed :: proc(gc: ^Game_Client, team: Team_ID) -> bool {
	if !gc.have_lobby {
		return true
	}
	counts: [TEAM_COUNT]int
	for i in 0..<TEAM_COUNT {
		counts[i] = int(gc.lobby.humans[i])
	}
	idx := team_index(team)
	if idx < 0 || counts[idx] >= int(gc.lobby.team_size) {
		return false
	}
	return team_join_allowed(counts, team)
}

client_reset_to_lobby :: proc(gc: ^Game_Client) {
	client_world_reset_session(&gc.client_world)
	client_audio_reset()
	gc.phase = .Connecting
	gc.have_lobby = false
	gc.hello_timer = 0
	gc.history_count = 0
	gc.sim_accum = 0
	gc.is_spectating = false
	gc.menu_selected = 0
}

client_poll_network :: proc(gc: ^Game_Client) {
	for _ in 0..<64 {
		packet, ok := network_client_poll(&gc.network)
		if !ok {
			break
		}
		gc.last_packet_time = gc.client_world.local_time

		#partial switch packet.kind {
		case .Server_Lobby:
			gc.lobby = packet.lobby
			gc.have_lobby = true
			if packet.lobby.reject != .None {
				gc.reject_reason = packet.lobby.reject
				gc.reject_timer = 3.0
				if gc.phase == .Joining {
					gc.phase = .Team_Select
				}
			} else if gc.phase == .Connecting {
				gc.phase = .Team_Select
				fmt.println("[Client] Lobby received")
			}

		case .Server_Welcome:
			if gc.phase == .Playing || gc.phase == .In_Menu {
				// Team switch completed while already in the match
				old_team := gc.client_world.local_team
				gc.client_world.local_entity_id = packet.welcome.your_entity_id
				gc.client_world.local_team = packet.welcome.team
				if packet.welcome.team != .Spectator {
					gc.view_yaw = wrap_angle(team_angle(packet.welcome.team) + f32(math.PI))
					gc.view_pitch = 0
				}
				gc.is_spectating = packet.welcome.team == .Spectator
				gc.phase = .Playing
				gc.history_count = 0
				gc.sim_accum = 0
				gc.cooldowns = {}
				gc.client_world.prediction.initialized = false
				client_drop_charge(gc)
				fmt.printf("[Client] Switched from %s to %s", team_name(old_team), team_name(packet.welcome.team))
				if packet.welcome.your_entity_id != INVALID_ENTITY {
					fmt.printf(" as entity %d\n", packet.welcome.your_entity_id)
				} else {
					fmt.printf("\n")
				}
			} else {
				client_world_reset_session(&gc.client_world)
				gc.client_world.local_entity_id = packet.welcome.your_entity_id
				gc.client_world.local_team = packet.welcome.team
				if packet.welcome.team != .Spectator {
					gc.view_yaw = wrap_angle(team_angle(packet.welcome.team) + f32(math.PI))
				} else {
					gc.view_yaw = 0
				}
				gc.view_pitch = 0
				gc.history_count = 0
				gc.sim_accum = 0
				gc.cooldowns = {}
				gc.is_spectating = packet.welcome.team == .Spectator
				gc.phase = .Playing
				fmt.printf("[Client] Joined %s", team_name(packet.welcome.team))
				if packet.welcome.your_entity_id != INVALID_ENTITY {
					fmt.printf(" as entity %d\n", packet.welcome.your_entity_id)
				} else {
					fmt.printf("\n")
				}
			}

		case .Server_Snapshot:
			if gc.phase == .Playing || gc.phase == .In_Menu {
				snap := packet.snapshot
				client_world_apply_snapshot(&gc.client_world, &snap)
			}

		case .Server_GameState:
			gc.client_world.game_state = packet.gamestate
			gc.client_world.have_game_state = true
			client_world_apply_gamestate_towers(&gc.client_world, &packet.gamestate)

		case .Server_Roster:
			roster := packet.roster
			client_world_apply_roster(&gc.client_world, &roster)
		}
	}
}

// Mouse look is applied to the view immediately (not quantized to sim ticks);
// movement keys are gathered into move_input for the next sim ticks.
client_handle_input :: proc(gc: ^Game_Client, dt: f32) {
	// Spectators can still look around but don't send inputs to the server
	if gc.is_spectating {
		if input_consume_click() && input.window_focused {
			sapp.lock_mouse(true)
		}
		if sapp.mouse_locked() {
			dx, dy := input_consume_look()
			gc.view_yaw = wrap_angle(gc.view_yaw - dx * CAM_LOOK_SENS)
			gc.view_pitch = clampf(gc.view_pitch - dy * CAM_LOOK_SENS, -CAM_PITCH_MAX, CAM_PITCH_MAX)
		} else {
			_, _ = input_consume_look()
		}
		gc.move_input = {}
		gc.aim_locked = false
		_ = input_consume_jump()
		// Clear slot presses
		for slot in 1..=HOTBAR_SLOTS {
			_ = input_consume_slot(slot)
		}
		return
	}

	if !sapp.mouse_locked() {
		if input_consume_click() && input.window_focused {
			sapp.lock_mouse(true)
		}
		_, _ = input_consume_look()
		gc.move_input = {}
		gc.aim_locked = false
		_ = input_consume_jump()
		return
	}

	dx, dy := input_consume_look()
	gc.view_yaw = wrap_angle(gc.view_yaw - dx * CAM_LOOK_SENS)
	gc.view_pitch = clampf(gc.view_pitch - dy * CAM_LOOK_SENS, -CAM_PITCH_MAX, CAM_PITCH_MAX)

	fwd: f32 = 0
	str: f32 = 0
	if input.key_w { fwd += 1 }
	if input.key_s { fwd -= 1 }
	if input.key_d { str += 1 }
	if input.key_a { str -= 1 }
	l := math.sqrt(fwd * fwd + str * str)
	if l > 1 {
		fwd /= l
		str /= l
	}
	gc.move_input.move_fwd = fwd
	gc.move_input.move_str = str
	gc.move_input.sprint = input.key_shift
	// Hold Space to jump; also latch a press that landed between sim ticks.
	if input_consume_jump() || input.key_space {
		gc.move_input.jump = true
	}

	// The lock is only claimed on the wire when it actually ran, so the server
	// never charges stamina for a right button held over empty air.
	gc.move_input.aim_lock = client_apply_aim_lock(gc, dt)

	for slot in 1..=HOTBAR_SLOTS {
		if input_consume_slot(slot) {
			gc.selected_slot = slot - 1
		}
	}
}

// Aiming is the only thing that picks a target, so anything that stops the
// player aiming drops it the same way it drops a charge. When switching spells,
// clear the target if it's invalid for the new spell's filter, or retarget
// under the crosshair if a valid one is there.
client_update_target :: proc(gc: ^Game_Client) {
	pred := &gc.client_world.prediction
	if gc.phase != .Playing || gc.is_spectating || !sapp.mouse_locked() || !pred.initialized || pred.predicted_char.dead {
		gc.client_world.target_id = INVALID_ENTITY
		return
	}
	// The cast origin the server will use, not the bobbing render camera.
	eye := pred.predicted_char.pos + vec3{0, 0, PLAYER_EYE_M}
	look := camera_forward(gc.view_yaw, gc.view_pitch)

	// Get the currently selected spell's filter
	spell := HOTBAR[gc.selected_slot]
	filter := SPELL_DEFS[spell].target_filter

	// If the current target doesn't match the new filter, clear it and try to retarget
	if !client_world_target_valid_for_spell(&gc.client_world, gc.client_world.target_id, filter) {
		gc.client_world.target_id = INVALID_ENTITY
	}

	client_world_acquire_target(&gc.client_world, eye, look, filter)
}

// Run as many 60Hz ticks as the accumulator allows, predicting locally and
// sending each input (with two previous ones) to the server.
client_step_simulation :: proc(gc: ^Game_Client, dt: f32) {
	// Spectators don't simulate
	if gc.is_spectating {
		return
	}

	gc.sim_accum += dt
	ticks := 0
	for gc.sim_accum >= FIXED_DT && ticks < 5 {
		gc.sim_accum -= FIXED_DT
		ticks += 1

		input := gc.move_input
		input.yaw = gc.view_yaw
		input.pitch = gc.view_pitch
		input.target_id = gc.client_world.target_id
		input.cast_spell, input.charge_spell = client_decide_cast(gc)

		qinput := input_quantize(input)
		gc.client_world.client_tick += 1
		client_prediction_step(&gc.client_world.prediction, gc.client_world.client_tick, qinput)

		// History shift (newest first)
		for i := INPUT_REDUNDANCY - 1; i > 0; i -= 1 {
			gc.input_history[i] = gc.input_history[i - 1]
		}
		gc.input_history[0] = qinput
		gc.history_count = min(gc.history_count + 1, INPUT_REDUNDANCY)

		packet := Client_Input_Packet{
			newest_tick = gc.client_world.client_tick,
			count       = u8(gc.history_count),
			inputs      = gc.input_history,
		}
		network_client_send_input(&gc.network, &packet)
	}
	if ticks == 5 && gc.sim_accum > FIXED_DT {
		gc.sim_accum = 0 // we fell too far behind; drop the remainder
	}
	if ticks > 0 {
		gc.move_input.jump = false
	}
	gc.render_alpha = gc.sim_accum / FIXED_DT
}

// Hold LMB to wind the selected spell up. Letting go before the bar is full
// commits the cast: it keeps charging and fires at full power once it is.
// Holding through the full wind-up still waits for the release, so a shot can
// be timed. Beams are unchanged — they run only while the button is down.
// Mirrors the server's checks so the HUD stays responsive and we don't spam
// rejected casts; the server still times the charge itself.
client_decide_cast :: proc(gc: ^Game_Client) -> (cast_spell: Spell_ID, charge_spell: Spell_ID) {
	pred := &gc.client_world.prediction
	alive := pred.initialized && !pred.predicted_char.dead
	match_over := gc.client_world.have_game_state && Match_State(gc.client_world.game_state.match_state) == .Ended

	// Dying, unlocking the mouse or the match ending drop the wind-up on the
	// floor, committed or not.
	if !alive || match_over || !sapp.mouse_locked() {
		client_sfx_note_fizzle(gc)
		client_drop_charge(gc)
		return .None, .None
	}

	// The cast origin and look the server will judge a targeted spell by.
	eye := pred.predicted_char.pos + vec3{0, 0, PLAYER_EYE_M}
	look := camera_forward(gc.view_yaw, gc.view_pitch)
	holding := input.held_left
	selected := HOTBAR[gc.selected_slot]
	winding := gc.charging_spell != .None && SPELL_DEFS[gc.charging_spell].payload != .Beam

	if holding {
		spell := selected
		def := &SPELL_DEFS[spell]
		if gc.charging_spell != spell {
			// A fresh hold, or the player swapped slots mid-charge. Picking the
			// spell up again once its cooldown ends is deliberate: holding
			// through the cooldown starts the next wind-up automatically.
			if !spell_castable(spell, pred.predicted_char, gc.cooldowns[spell]) {
				client_sfx_note_fizzle(gc)
				client_drop_charge(gc)
				return .None, .None
			}
			// A strike needs someone to call it on, in range, when it starts.
			// Cover is not asked about until it fires: the target is free to
			// duck, and the caster is free to wait them out.
			if def.payload == .Strike {
				target, ok := client_world_strike_target(&gc.client_world)
				if !ok || !strike_target_in_range(def, eye, look, target.display_state.pos) {
					client_sfx_note_fizzle(gc)
					client_drop_charge(gc)
					return .None, .None
				}
			}
			// A heal can start on the caster alone. At full health it needs a
			// wounded ally in range, the same way a strike needs a hostile.
			if def.payload == .Heal && pred.predicted_char.health >= HEALTH_MAX {
				target, ok := client_world_heal_target(&gc.client_world)
				if !ok || target.display_state.health >= HEALTH_MAX ||
				   !strike_target_in_range(def, eye, look, target.display_state.pos) {
					client_sfx_note_fizzle(gc)
					client_drop_charge(gc)
					return .None, .None
				}
			}
			gc.charging_spell = spell
			gc.charge_accum = 0
			gc.charge_committed = false
		}
	} else if winding {
		// Button up on a charge-cast: swapping off it cancels, otherwise an
		// early release commits the remaining wind-up.
		if selected != gc.charging_spell {
			client_sfx_note_fizzle(gc)
			client_drop_charge(gc)
			return .None, .None
		}
		if !gc.charge_committed && spell_charge_frac(&SPELL_DEFS[gc.charging_spell], gc.charge_accum) < 1 {
			gc.charge_committed = true
		}
	} else {
		// Idle, or letting go of a beam (there is nothing to fire).
		client_drop_charge(gc)
		return .None, .None
	}

	def := &SPELL_DEFS[gc.charging_spell]
	if def.payload == .Beam {
		// A beam is firing for as long as this is held, so the hand stays
		// lit. Mana reaching zero means the server has just put the beam
		// to rest; mirror the rest so the bar shows it, and let go of the
		// spell so holding through it relights the beam when it ends.
		gc.cast_pulse = max(gc.cast_pulse, 0.7)
		if pred.predicted_char.mana < 1 {
			gc.cooldowns[gc.charging_spell] = def.cooldown_sec
			client_drop_charge(gc)
			return .None, .None
		}
		gc.charge_accum = min(gc.charge_accum + FIXED_DT, def.cast_time)
		return .None, gc.charging_spell
	}

	// Losing the target mid-wind-up (they died, or the crosshair moved on to
	// a teammate) drops the charge so the player can start over at once
	// rather than find out when it fires. A heal at full health is the same
	// for its ally; a wounded caster keeps winding even if the ally is gone.
	if def.payload == .Strike {
		if _, ok := client_world_strike_target(&gc.client_world); !ok {
			client_sfx_note_fizzle(gc)
			client_drop_charge(gc)
			return .None, .None
		}
	}
	if def.payload == .Heal && pred.predicted_char.health >= HEALTH_MAX {
		target, ok := client_world_heal_target(&gc.client_world)
		if !ok || target.display_state.health >= HEALTH_MAX {
			client_sfx_note_fizzle(gc)
			client_drop_charge(gc)
			return .None, .None
		}
	}

	gc.charge_accum = min(gc.charge_accum + FIXED_DT, def.cast_time)
	full := spell_charge_frac(def, gc.charge_accum) >= 1
	if full && (!holding || gc.charge_committed) {
		return client_finish_cast(gc, eye, look)
	}
	return .None, gc.charging_spell
}

client_finish_cast :: proc(gc: ^Game_Client, eye, look: vec3) -> (cast_spell: Spell_ID, charge_spell: Spell_ID) {
	pred := &gc.client_world.prediction
	spell := gc.charging_spell
	def := &SPELL_DEFS[spell]
	client_drop_charge(gc)
	// A strike whose target is out of reach fizzles here for the same reason
	// the server would refuse it, and without pretending a cooldown started.
	if def.payload == .Strike {
		target, ok := client_world_strike_target(&gc.client_world)
		if !ok || !strike_target_in_reach(def, eye, look, target.display_state.pos) {
			client_audio_play(.Fizzle)
			return .None, .None
		}
	}
	// A heal with nobody missing health, or whose only ally has ducked out of
	// reach, fizzles the same way.
	if def.payload == .Heal {
		self_ok := pred.predicted_char.health < HEALTH_MAX
		ally_ok := false
		if target, ok := client_world_heal_target(&gc.client_world); ok &&
		   target.display_state.health < HEALTH_MAX {
			ally_ok = strike_target_in_reach(def, eye, look, target.display_state.pos)
		}
		if !self_ok && !ally_ok {
			client_audio_play(.Fizzle)
			return .None, .None
		}
	}

	gc.cooldowns[spell] = def.cooldown_sec
	gc.cast_pulse = 1
	gc.last_cast = spell
	camera_fx_on_cast(&gc.fx, spell)
	client_sfx_play_cast(spell)
	return spell, .None
}

client_drop_charge :: proc(gc: ^Game_Client) {
	gc.charging_spell = .None
	gc.charge_accum = 0
	gc.charge_committed = false
}

// Handle menu input and actions
client_handle_menu_input :: proc(gc: ^Game_Client) {
	// Menu has 4 options: Join Alpha (1), Join Beta (2), Join Gamma (3), Spectate (4)
	for slot in 1..=4 {
		if input_consume_slot(slot) {
			idx := slot - 1
			if idx < TEAM_COUNT {
				// Join a team
				team := team_from_index(idx)
				if client_team_allowed(gc, team) {
					gc.chosen_team = team
					network_client_send_join(&gc.network, team, gc.player_name)
					fmt.printf("[Client] Switching to team %s\n", team_name(team))
				} else {
					fmt.printf("[Client] Cannot join %s - most populated\n", team_name(team))
				}
			} else if idx == 3 {
				network_client_send_join(&gc.network, .Spectator, gc.player_name)
				fmt.println("[Client] Entering spectator mode")
			}
		}
	}
	// Clear other slot presses
	for slot in 5..=HOTBAR_SLOTS {
		_ = input_consume_slot(slot)
	}
	_ = input_consume_click()
}

AIM_LOCK_PULL_RATE :: f32(3.5)   // radians per second the view is drawn in

// Hold the right button to lean on the sticky target: the view is drawn toward
// it at a fixed rate rather than snapped, so the help is tracking rather than
// a shot placed for you, and the whole time it runs the stamina bar empties
// faster than a sprint. It pulls to `strike_center`, the same point the server
// validates a strike against, so the assist lands the crosshair exactly where
// a cast is legal instead of somewhere near it.
//
// Returns whether the lock ran this frame; that answer is what goes on the
// wire and what the server bills for.
client_apply_aim_lock :: proc(gc: ^Game_Client, dt: f32) -> bool {
	pred := &gc.client_world.prediction
	world := &gc.client_world

	if !input.held_right || !pred.initialized || pred.predicted_char.dead {
		gc.aim_locked = false
		return false
	}

	// An empty bar drops the lock, and it takes a real recovery to get it
	// back; otherwise it would stutter back on every tick that regenerates.
	stamina := pred.predicted_char.stamina
	if stamina <= 0 {
		gc.aim_locked = false
	} else if !gc.aim_locked && stamina >= STAMINA_AIM_LOCK_MIN {
		gc.aim_locked = true
	}
	if !gc.aim_locked {
		return false
	}

	// Only hostiles. Heal has its own sticky target and dragging the view onto
	// an ally would fight the player rather than help them.
	target_id := world.target_id
	if target_id == INVALID_ENTITY || int(target_id) >= MAX_ENTITIES {
		return false
	}
	remote := &world.remote_entities[int(target_id)]
	if !remote.active || remote.display_state.dead {
		return false
	}
	if !teams_are_enemies(world.local_team, remote.team) {
		return false
	}

	eye := pred.predicted_char.pos + vec3{0, 0, PLAYER_EYE_M}
	to_target := strike_center(remote.display_state.pos) - eye
	dist := len_vec3(to_target)
	if dist < 0.5 {
		return false
	}
	to_target /= dist

	step := AIM_LOCK_PULL_RATE * dt
	yaw_delta := wrap_angle(math.atan2(to_target.y, to_target.x) - gc.view_yaw)
	gc.view_yaw = wrap_angle(gc.view_yaw + clampf(yaw_delta, -step, step))

	target_pitch := math.asin(clampf(to_target.z, -1, 1))
	pitch_delta := target_pitch - gc.view_pitch
	gc.view_pitch = clampf(gc.view_pitch + clampf(pitch_delta, -step, step), -CAM_PITCH_MAX, CAM_PITCH_MAX)

	return true
}

main_client :: proc() {
	sapp.run({
		init_cb       = client_init,
		frame_cb      = client_frame,
		cleanup_cb    = client_cleanup,
		event_cb      = input_event,
		width         = WINDOW_W,
		height        = WINDOW_H,
		sample_count  = 1,
		high_dpi      = false,
		window_title  = "Nexus Arena",
		icon          = {sokol_default = true},
		logger        = {func = slog.func},
		swap_interval = 1,
	})
}

main :: proc() {
	main_client()
}
