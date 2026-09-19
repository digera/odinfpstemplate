package main

// Client renderer: fullscreen analytic ray tracer (shaders/scene.glsl) plus a
// debug-text HUD. Also owns the camera feel (bob, landing dip, kicks, flashes).

import "core:fmt"
import "core:time"
import "core:math"
import "core:strings"
import sapp "sokol:app"
import sdtx "sokol:debugtext"
import sg "sokol:gfx"
import sglue "sokol:glue"
import slog "sokol:log"

camera_forward :: proc(yaw, pitch: f32) -> vec3 {
	cp := math.cos(pitch)
	return {math.cos(yaw) * cp, math.sin(yaw) * cp, math.sin(pitch)}
}

camera_right :: proc(yaw: f32) -> vec3 {
	return {math.sin(yaw), -math.cos(yaw), 0}
}

SDTX_ORIGIN_CELLS :: f32(1)
SDTX_CHAR_PX      :: f32(8)
SDTX_CANVAS_SCALE :: f32(0.5)

// ---------------------------------------------------------------------------
// Robes

// A wisp's robe, one per remote entity. Keyed by entity id rather than by the
// distance-sorted wisp slot, which reshuffles every frame. The cloth is a
// two-link chain: a waist ring hangs from the shoulders on a short rope and the
// hem ring hangs from the waist on a longer one. Each link is a damped pendulum
// pushed back by drag from travel, so motion arrives at the waist first and
// reaches the hem a beat later: the robe bends and flows rather than tilting
// as one piece. The pleat pattern's yaw lags the body's so a turn twists the
// cloth. The shader (robe_trace) draws the surface through these two points.
//
// Simulated in the wearer's frame: the rings are offsets from what they hang
// from, and the wearer's acceleration enters as an inertial force. At a steady
// walk the cloth then sits exactly where the drag puts it whatever the frame
// rate, a stop throws the body's momentum into the hem as a forward swing, and
// a Blink moves the cloth with the body without disturbing it.
Robe_State :: struct {
	waist_off: vec3,   // waist ring from the shoulder ring
	waist_vel: vec3,   // in the wearer's frame
	hem_off:   vec3,   // hem ring from the waist ring
	hem_vel:   vec3,
	prev_vel:  vec3,   // wearer velocity last frame, for the inertial force
	hem_yaw:   f32,    // the yaw the pleats have caught up to
	flutter:   f32,    // 0..1 smoothed travel speed; drives the hem ripple
	settled:   bool,   // false until the entity has been drawn once
	death_t:   f32,    // seconds since the wisp died, 0 while it lives, held at DEATH_ANIM_SEC once it is gone
	was_dead:  bool,   // what death_t was last advanced against, to catch the death and the way back
	death_hp:  f32,    // the size it was the last frame it lived; it swells from the body everyone just saw
}

ROBE_SHOULDER_Z_M   :: f32(0.45)   // shoulder ring above the wisp centre, at full size; matches the shader
ROBE_WAIST_ROPE_M   :: f32(0.55)   // shoulder ring to waist ring, at full size
ROBE_HEM_ROPE_M     :: f32(0.70)   // waist ring to hem ring
ROBE_WAIST_DRAG_S   :: f32(0.015)  // metres of trail per m/s of travel; the cloth is snug at the waist
ROBE_WAIST_TRAIL_M  :: f32(0.08)
ROBE_HEM_DRAG_S     :: f32(0.045)  // and loose at the hem
ROBE_HEM_TRAIL_M    :: f32(0.26)
ROBE_WAIST_SWING_M  :: f32(0.09)   // how far each ring may swing out before the cloth meets the body
ROBE_HEM_SWING_M    :: f32(0.28)
ROBE_WAIST_SPRING   :: f32(90.0)   // stiff and quick: follows the body closely
ROBE_WAIST_DAMPING  :: f32(10.0)
ROBE_HEM_SPRING     :: f32(40.0)   // soft: swings at ~1 Hz, one visible overshoot
ROBE_HEM_DAMPING    :: f32(5.0)
ROBE_JOLT_MAX_MPS   :: f32(8.0)    // most the wearer's velocity may change in one frame, for the cloth's purposes
ROBE_SIM_DT_MIN     :: f32(1.0 / 1000.0)
ROBE_SIM_DT_MAX     :: f32(1.0 / 30.0)

// A killed wisp swells where it fell and bursts into a flash the colour of its
// team. The phases are timed here and read by the shader off robe_fx[i].y, so
// every client that can see it sees the same swell and the same burst; these
// match DEATH_SWELL_SEC and DEATH_POP_SEC in the shader.
DEATH_SWELL_SEC     :: f32(0.40)   // how long the robe fills before it goes
DEATH_POP_SEC       :: f32(0.12)   // how long the flash it bursts into lasts
DEATH_ANIM_SEC      :: DEATH_SWELL_SEC + DEATH_POP_SEC

// Drag from moving through the air, pushing the cloth back against travel, up
// to what the rope allows.
@(private = "file")
robe_drag :: proc(vel: vec3, per_mps, limit: f32) -> vec3 {
	drag := vec3{-vel.x, -vel.y, 0} * per_mps
	if l := len_vec3(drag); l > limit {
		drag = drag * (limit / l)
	}
	return drag
}

// One link of the chain: a ring on a rope of fixed length below what it hangs
// from, sprung toward `target`, pushed by the `inertial` force of its frame
// accelerating, and allowed to swing out at most `swing` sideways before the
// cloth meets the body. Position-based: integrate, project onto the
// constraints, then take the velocity from the displacement that actually
// happened, so being stopped by the rope or the body shows up as momentum.
// Returns the ring's acceleration, which is the inertial force felt by
// whatever hangs from it.
@(private = "file")
robe_link :: proc(off, vel: ^vec3, target, inertial: vec3, rope, swing, spring, damping, dt: f32) -> (acc: vec3) {
	prev_off := off^
	prev_vel := vel^
	vel^ += ((target - off^) * spring - vel^ * damping + inertial) * dt
	d := off^ + vel^ * dt

	lateral := math.sqrt(d.x * d.x + d.y * d.y)
	if lateral > swing {
		d.x *= swing / lateral
		d.y *= swing / lateral
		lateral = swing
	}
	// Hanging below at rope length: the ring lifts as it swings out
	d.z = -math.sqrt(max(rope * rope - lateral * lateral, 0))
	off^ = d
	vel^ = (d - prev_off) * (1.0 / dt)
	return (vel^ - prev_vel) * (1.0 / dt)
}

// One frame of cloth motion. `vel` is the wearer's velocity (server-
// authoritative, interpolated), `yaw` its facing, `scale` the wisp's size (it
// shrinks as it is hurt), `dead` whether the server says the wisp is down.
robe_simulate :: proc(st: ^Robe_State, vel: vec3, yaw, scale, world_t, phase, dt: f32, dead: bool) {
	// A wisp that dies swells and bursts where it fell, and respawns somewhere
	// else, so the cloth it comes back in starts at rest rather than carrying on
	// from the balloon it went out as.
	if dead != st.was_dead {
		st.was_dead = dead
		st.death_t = 0
		if !dead {
			st.settled = false
		}
	}

	waist_rope := ROBE_WAIST_ROPE_M * scale
	hem_rope := ROBE_HEM_ROPE_M * scale
	if !st.settled {
		st.waist_off = {0, 0, -waist_rope}
		st.waist_vel = {}
		st.hem_off = {0, 0, -hem_rope}
		st.hem_vel = {}
		st.prev_vel = vel
		st.hem_yaw = yaw
		st.flutter = 0
		st.settled = true
		// A wisp already down the first time it is simulated burst while this
		// client was not watching it; it stays gone rather than replaying a
		// death nobody saw.
		st.was_dead = dead
		st.death_t = dead ? DEATH_ANIM_SEC : 0
	}

	if dead {
		st.death_t = min(st.death_t + dt, DEATH_ANIM_SEC)
	}

	// The wearer speeding up throws the cloth back; stopping throws it forward.
	// A snapshot that teleports the velocity is taken as a hard jolt, not a
	// launch.
	jolt := st.prev_vel - vel
	if l := len_vec3(jolt); l > ROBE_JOLT_MAX_MPS {
		jolt = jolt * (ROBE_JOLT_MAX_MPS / l)
	}
	inertial := jolt * (1.0 / dt)
	st.prev_vel = vel

	waist_target := vec3{0, 0, -waist_rope} + robe_drag(vel, ROBE_WAIST_DRAG_S, ROBE_WAIST_TRAIL_M)
	waist_acc := robe_link(&st.waist_off, &st.waist_vel, waist_target, inertial, waist_rope, ROBE_WAIST_SWING_M * scale,
		ROBE_WAIST_SPRING, ROBE_WAIST_DAMPING, dt)

	// The hem hangs from the waist and feels the waist's acceleration too, so
	// motion works its way down the cloth a beat at a time.
	hem_target := vec3{0, 0, -hem_rope} + robe_drag(vel, ROBE_HEM_DRAG_S, ROBE_HEM_TRAIL_M)
	// A slow wander so a wisp standing still is never quite still.
	hem_target.x += 0.03 * math.sin(world_t * 0.9 + phase)
	hem_target.y += 0.03 * math.cos(world_t * 0.7 + phase * 1.3)
	robe_link(&st.hem_off, &st.hem_vel, hem_target, inertial - waist_acc, hem_rope, ROBE_HEM_SWING_M * scale,
		ROBE_HEM_SPRING, ROBE_HEM_DAMPING, dt)

	// Pleats catch up with the body's facing a beat late
	st.hem_yaw = wrap_angle(st.hem_yaw + wrap_angle(yaw - st.hem_yaw) * min(dt * 7.0, 1.0))
	speed := math.sqrt(vel.x * vel.x + vel.y * vel.y)
	st.flutter += (clampf(speed / CHARACTER_WALK_SPEED, 0, 1) - st.flutter) * min(dt * 5.0, 1.0)
}

Client_Renderer :: struct {
	pip:         sg.Pipeline,
	bind:        sg.Bindings,
	pass_action: sg.Pass_Action,

	fps_accum:    f64,
	fps_presents: int,
	last_fps:     f32,
	frame_ms:     f32,
	world_t:      f32,
	perf_accum:   f64,
	perf_frames:  int,

	robes:        [MAX_ENTITIES]Robe_State,

	// Where each wisp's cast orb ended up this frame. A beam pours out of the
	// orb rather than out of the middle of the robe, and the beam pass runs
	// after the wisps, so the positions have to outlive the loop that made them.
	// w is 1 where there is an orb at all.
	orbs:         [MAX_ENTITIES]vec4,

	// Tower node state for minimal rendering (no SDF march for this PR)
	tower_seen:   [MAX_PYLONS]int,  // live_count last rendered
	tower_dirty:  [MAX_PYLONS]bool,
}

// The atlas stacks slabs along Z. Trilinear filtering therefore has to be kept
// off the seams between them, which the shader does by clamping its sample
// coordinate half a texel inside each slab.
PYLON_ATLAS_NZ    :: PYLON_NZ * MAX_PYLONS
// ---------------------------------------------------------------------------
// Camera feel

Camera_FX :: struct {
	bob_phase:   f32,
	bob_amount:  f32,
	land_dip:    f32,
	land_vel:    f32,
	hurt:        f32,
	mend:        f32,
	flash:       f32,
	fov_kick:    f32,
	cast_kick:   f32,
	roll:        f32,
	sprint_blend: f32,
	prev_on_ground: bool,
	prev_vel_z:  f32,
}

camera_fx_init :: proc(fx: ^Camera_FX) {
	fx^ = {}
	fx.prev_on_ground = true
}

camera_fx_on_cast :: proc(fx: ^Camera_FX, spell: Spell_ID) {
	#partial switch spell {
	case .Arcane_Missile: fx.cast_kick += 0.010
	case .Arcane_Orb:     fx.cast_kick += 0.028; fx.fov_kick = max(fx.fov_kick, 0.35)
	case .Frost_Lance:    fx.cast_kick += 0.020
	case .Call_Lightning: fx.cast_kick += 0.030; fx.fov_kick = max(fx.fov_kick, 0.40)
	case .Blink:          // handled when the teleport lands
	case .Friendly_Heal:  fx.cast_kick += 0.012
	}
}

camera_fx_update :: proc(fx: ^Camera_FX, gc: ^Game_Client, dt: f32) {
	pred := &gc.client_world.prediction
	char := pred.predicted_char

	// Head bob scales with horizontal speed, only on the ground
	speed := math.sqrt(char.vel.x * char.vel.x + char.vel.y * char.vel.y)
	target_bob: f32 = 0
	if char.on_ground && !char.dead && pred.initialized {
		target_bob = clampf(speed / CHARACTER_WALK_SPEED, 0, 1.3)
	}
	fx.bob_amount += (target_bob - fx.bob_amount) * min(dt * 9.0, 1.0)
	fx.bob_phase += dt * (6.8 + speed * 0.45) * (char.on_ground ? 1.0 : 0.25)

	// Landing dip: a damped spring kicked by the impact velocity
	if !fx.prev_on_ground && char.on_ground && fx.prev_vel_z < -2.5 {
		fx.land_vel -= clampf(-fx.prev_vel_z * 0.035, 0.05, 0.30)
	}
	fx.prev_on_ground = char.on_ground
	fx.prev_vel_z = char.vel.z
	fx.land_vel += (-fx.land_dip * 220.0 - fx.land_vel * 16.0) * dt
	fx.land_dip += fx.land_vel * dt

	// Events from reconciliation
	if pred.damage_taken > 0 {
		fx.hurt = min(fx.hurt + pred.damage_taken / 45.0, 1.0)
		pred.damage_taken = 0
	}
	// Health arriving is the only confirmation a heal landed, so the mend
	// bloom is driven off the snapshot rather than off the release.
	if pred.healed > 0 {
		fx.mend = min(fx.mend + pred.healed / 45.0, 1.0)
		pred.healed = 0
	}
	if pred.teleported {
		fx.flash = 1.0
		fx.fov_kick = 1.0
		pred.teleported = false
	}
	if pred.respawned {
		fx.flash = 0.7
		pred.respawned = false
	}

	fx.hurt *= math.exp(-dt * 2.6)
	fx.mend *= math.exp(-dt * 2.2)
	fx.flash *= math.exp(-dt * 5.5)
	fx.fov_kick *= math.exp(-dt * 6.5)
	fx.cast_kick *= math.exp(-dt * 11.0)

	// A lit beam shivers the view a little for as long as it is held.
	if _, lit := client_world_local_beam(&gc.client_world); lit {
		t := f32(gc.client_world.local_time)
		fx.cast_kick = max(fx.cast_kick, 0.0025 + 0.0025 * math.sin(t * 41.0) * math.sin(t * 13.0))
	}

	// Lean into strafes
	right := camera_right(gc.view_yaw)
	lateral := char.vel.x * right.x + char.vel.y * right.y
	target_roll := -lateral * 0.006
	fx.roll += (target_roll - fx.roll) * min(dt * 8.0, 1.0)

	sprinting := gc.move_input.sprint && speed > CHARACTER_WALK_SPEED * 1.1 && char.on_ground
	fx.sprint_blend += ((sprinting ? 1.0 : 0.0) - fx.sprint_blend) * min(dt * 6.0, 1.0)
}

// ---------------------------------------------------------------------------

client_renderer_init :: proc(r: ^Client_Renderer) {
	sg.setup({
		environment = sglue.environment(),
		logger = {func = slog.func},
	})
	sdtx.setup({
		fonts = {0 = sdtx.font_c64()},
		logger = {func = slog.func},
	})

	verts := [?]f32{-1, -1, 3, -1, -1, 3}
	r.bind.vertex_buffers[0] = sg.make_buffer({
		data = {ptr = &verts, size = size_of(verts)},
	})

	r.pip = sg.make_pipeline({
		shader = sg.make_shader(scene_shader_desc(sg.query_backend())),
		layout = {attrs = {ATTR_scene_position = {format = .FLOAT2}}},
		depth = {write_enabled = false, compare = .ALWAYS},
		label = "scene",
	})

	// Towers: minimal rendering (crude boxes for nodes, no SDF march this PR)
	// No GPU state needed for simple box/capsule drawing

	r.pass_action = {
		colors = {0 = {load_action = .CLEAR, clear_value = {0.02, 0.02, 0.04, 1}}},
	}

	fmt.println("[Renderer] Sokol ready, backend:", sg.query_backend())
}

client_renderer_shutdown :: proc(r: ^Client_Renderer) {
	sdtx.shutdown()
	sg.shutdown()
}

// Stub: towers rendered as simple geometry, no texture upload needed for this PR
@(private = "file")
client_renderer_update_towers :: proc(r: ^Client_Renderer, world: ^Tower_World, dt: f32) {
	// Track which towers changed for future optimizations
	for i in 0 ..< MAX_PYLONS {
		t := tower_get(world, Pylon_ID(i))
		if t != nil && t.live_count != r.tower_seen[i] {
			r.tower_seen[i] = t.live_count
			r.tower_dirty[i] = true
		}
	}
}

// Render type codes for the shader's spell_tint; an appearance, not the
// Spell_ID, so spells that share a look can share a code. Zero is nothing to
// draw, which is what a cast orb asks about.
@(private = "file")
spell_type_code :: proc(spell: Spell_ID) -> f32 {
	#partial switch spell {
	case .Arcane_Missile: return 1
	case .Arcane_Orb:     return 2
	case .Blink:          return 3
	case .Frost_Lance:    return 4
	case .Call_Lightning: return 5
	case .Thunderbolt:    return 6
	case .Friendly_Heal:  return 7
	}
	return 0
}

// Where a wisp holds its cast orb: out past the right hand and carried along
// the aim, so it rises when they look up and drops when they look down. Close
// enough to the robe that the light spills onto the cloth, far enough out that
// even the heaviest orb clears the cloth instead of sinking into it.
CAST_ORB_SIDE_M  :: f32(0.28)   // out to the wisp's right of centre
CAST_ORB_REACH_M :: f32(0.40)   // forward along the aim
CAST_ORB_RISE_M  :: f32(0.14)   // above the wisp's centre

@(private = "file")
cast_orb_pos :: proc(center: vec3, yaw: f32, aim: vec3, scale: f32) -> vec3 {
	return center +
	       camera_right(yaw) * (CAST_ORB_SIDE_M * scale) +
	       aim * (CAST_ORB_REACH_M * scale) +
	       vec3{0, 0, CAST_ORB_RISE_M * scale}
}

@(private = "file")
pack_box :: proc(b: ^World_Box) -> (a, c: vec4) {
	return vec4{b.center.x, b.center.y, b.center.z, math.sin(b.yaw)},
	       vec4{b.half.x, b.half.y, b.half.z, math.cos(b.yaw)}
}

client_renderer_draw :: proc(r: ^Client_Renderer, gc: ^Game_Client) {
	t0 := time.tick_now()
	dt := f32(sapp.frame_duration())
	r.world_t += dt
	// A hitch must not launch the hem springs, and the sim divides by dt
	robe_dt := clampf(dt, ROBE_SIM_DT_MIN, ROBE_SIM_DT_MAX)

	world := &gc.client_world
	pred := &world.prediction
	fx := &gc.fx
	in_match := gc.phase == .Playing || gc.phase == .In_Menu
	playing := in_match && pred.initialized && !gc.is_spectating

	// --- Camera --------------------------------------------------------------
	base_pos: vec3
	yaw := gc.view_yaw
	pitch := gc.view_pitch
	if playing {
		base_pos = client_prediction_render_pos(pred, gc.render_alpha)
	} else if in_match {
		// Spectator / no body yet: free-look from above the plaza.
		base_pos = {0, 0, 6}
	} else {
		// Lobby camera: slow orbit above the plaza looking at the center
		a := r.world_t * 0.10
		base_pos = {math.cos(a) * 12.5, math.sin(a) * 12.5, 4.5}
		yaw = wrap_angle(a + f32(math.PI))
		pitch = -0.22
	}

	right := camera_right(yaw)
	bob_z := math.sin(fx.bob_phase * 2.0) * 0.032 * fx.bob_amount
	bob_r := math.sin(fx.bob_phase) * 0.018 * fx.bob_amount
	eye := base_pos + vec3{0, 0, PLAYER_EYE_M + bob_z + fx.land_dip} + right * bob_r
	pitch = clampf(pitch - fx.cast_kick + math.sin(fx.bob_phase * 2.0) * 0.003 * fx.bob_amount, -CAM_PITCH_MAX - 0.1, CAM_PITCH_MAX + 0.1)

	fwd := camera_forward(yaw, pitch)
	up := norm_vec3(cross_vec3(right, fwd))
	// Roll
	if abs(fx.roll) > 1e-5 {
		c := math.cos(fx.roll)
		s := math.sin(fx.roll)
		nr := right * c + up * s
		nu := up * c - right * s
		right = nr
		up = nu
	}

	aspect := sapp.widthf() / sapp.heightf()
	fov := CAM_FOV_DEG + fx.fov_kick * 9.0 + fx.sprint_blend * 5.0
	half_h := math.tan(fov * math.PI / 360.0)
	half_w := half_h * max(aspect, 0.01)

	vs_params := Vs_Params{
		cam_pos     = eye,
		half_w      = half_w,
		cam_right   = right,
		half_h      = half_h,
		cam_up      = up,
		cam_forward = fwd,
	}

	// --- Fragment uniforms --------------------------------------------------
	fs_params: Fs_Params
	fs_params.cam_data = {eye.x, eye.y, eye.z, r.world_t}
	fs_params.fx = {fx.hurt, fx.flash, f32(u8(world.local_team)), gc.cast_pulse}
	dead: f32 = (playing && pred.predicted_char.dead) ? 1 : 0
	ended: f32 = (world.have_game_state && Match_State(world.game_state.match_state) == .Ended) ? 1 : 0
	fs_params.fx2 = {world.hit_marker, dead, ended, fx.mend}

	// Hand orb: lower right of the view, bobbing with the camera. It is this
	// player's end of the cast orb every opponent sees them holding, so it
	// takes the charging spell's colour and swells with the wind-up. What the
	// player reads in their own hand is what the arena reads on their wisp.
	if playing && dead < 0.5 {
		hand := eye + fwd * 0.62 + right * (0.27 + bob_r * 0.5) + up * (-0.25 + bob_z * 0.4 - fx.cast_kick * 1.5)
		code := spell_type_code(gc.charging_spell)
		charge: f32 = 0
		if code > 0 {
			charge = spell_charge_frac(&SPELL_DEFS[gc.charging_spell], gc.charge_accum)
		}
		fs_params.hand_pos = {hand.x, hand.y, hand.z, 1.0 + gc.cast_pulse * 0.9 + charge * 0.35}
		fs_params.hand_cast = {code, charge, 0, 0}
	}

	for i in 0..<NUM_FLOOR_BOXES {
		a, c := pack_box(&world_floor_boxes[i])
		fs_params.floor_boxes[2 * i] = a
		fs_params.floor_boxes[2 * i + 1] = c
	}
	for i in 0..<NUM_SOLID_BOXES {
		a, c := pack_box(&world_solid_boxes[i])
		fs_params.solid_boxes[2 * i] = a
		fs_params.solid_boxes[2 * i + 1] = c
	}

	client_renderer_update_towers(r, &world.towers, dt)
	for i in 0..<MAX_PYLONS {
		t := &world.towers.towers[i]
		// Stub shader params: no actual SDF march this PR
		fs_params.pylons[i] = {t.base.x, t.base.y, t.base.z, t.yaw}
		fs_params.pylon_shape[i] = {t.core_height, CORE_RADIUS, 0, f32(u8(t.ore))}
		fs_params.pylon_bound[i] = {0, t.core_height, SPIRAL_BASE_RADIUS, t.intact}
	}
	for i in 0..<MAX_SNAPSHOT_CHUNKS {
		c := &world.chunks[i]
		if !c.present {
			fs_params.chunks[i] = {}
			fs_params.chunk_fx[i] = {}
			continue
		}
		fs_params.chunks[i] = {c.pos.x, c.pos.y, c.pos.z, c.radius}
		fs_params.chunk_fx[i] = {f32(u8(c.ore)), c.seed / 8, c.rest ? 1 : 0, 0}
	}
	// Minions go up as the ore they are made of rather than as a team colour:
	// their team is legible because their team's rock is, and it is the same
	// read as the tower they came out of and the lump they will drop.
	for i in 0..<MAX_SNAPSHOT_MINIONS {
		m := &world.minions[i]
		if !m.present {
			fs_params.minions[i] = {}
			fs_params.minion_fx[i] = {}
			continue
		}
		fs_params.minions[i] = {m.pos.x, m.pos.y, m.pos.z, f32(u8(team_ore(m.team))) + 1}
		seed := f32(hash_u32(u32(m.id) * 2654435761) & 0xFFFF) / f32(0x10000)
		fs_params.minion_fx[i] = {m.yaw, m.hp, f32(u8(m.kind)), seed}
	}

	// Nearest living remote players → wisps
	{
		r.orbs = {}
		ids: [MAX_ENTITIES]int
		dist: [MAX_ENTITIES]f32
		n := 0
		for i in 0..<MAX_ENTITIES {
			remote := &world.remote_entities[i]
			if !remote.active || remote.count == 0 {
				// The robe of a wisp that left starts fresh when it is back
				r.robes[i].settled = false
				continue
			}
			// A wisp that is down is still drawn while it swells and bursts, and
			// is gone from the arena once it has. One whose robe is not being
			// simulated died out of this client's sight, so it never starts: a
			// burst nobody watched is not replayed when it comes back into view.
			if remote.display_state.dead && (!r.robes[i].settled || r.robes[i].death_t >= DEATH_ANIM_SEC) {
				continue
			}
			ids[n] = i
			dist[n] = len2_vec3(remote.display_state.pos - eye)
			n += 1
		}
		take := min(n, 16)
		for k in 0..<take {
			best := k
			for j in k + 1..<n {
				if dist[j] < dist[best] {
					best = j
				}
			}
			if best != k {
				ids[k], ids[best] = ids[best], ids[k]
				dist[k], dist[best] = dist[best], dist[k]
			}
			remote := &world.remote_entities[ids[k]]
			robe := &r.robes[ids[k]]
			dead := remote.display_state.dead
			hp := clampf(remote.display_state.health / HEALTH_MAX, 0.05, 0.95)
			// The server zeroes health on death, so a wisp killed outright would
			// shrink on the frame it died. It swells from the body everyone just
			// saw instead.
			if dead {
				hp = robe.death_hp
			} else {
				robe.death_hp = hp
			}
			pos := remote.display_state.pos
			// Idle bob, animated here once per wisp rather than per pixel
			phase := f32(ids[k]) * 2.21
			pos.x += 0.045 * math.sin(r.world_t * 1.37 + phase)
			pos.y += 0.045 * math.cos(r.world_t * 1.11 + phase * 0.83)
			pos.z += CHARACTER_HEIGHT_M * 0.50 + 0.06 * math.sin(r.world_t * 2.07 + phase)
			fs_params.wisps[k] = {pos.x, pos.y, pos.z, f32(u8(remote.team)) + hp}

			// The sticky target is framed where it is actually drawn, bob and
			// all, so the mark rides the body instead of hanging beside it.
			// Only a wisp near enough to be one of the sixteen gets one: a
			// frame around a body this client is not drawing marks nothing.
			if !dead && Entity_ID(ids[k]) == world.target_id {
				relation: f32 = teams_are_enemies(world.local_team, remote.team) ? 1 : 2
				fs_params.target_mark = {pos.x, pos.y, pos.z, relation}
			}

			// The robe hangs from the bobbing body and shrinks with the wisp
			// as it is hurt.
			scale := 0.82 + 0.18 * hp
			yaw := remote.display_state.yaw
			robe_simulate(robe, remote.display_state.vel, yaw, scale, r.world_t, phase, robe_dt, dead)
			waist := pos + vec3{0, 0, ROBE_SHOULDER_Z_M * scale} + robe.waist_off
			hem := waist + robe.hem_off
			fs_params.robes[k] = {hem.x, hem.y, hem.z, yaw}
			fs_params.robe_waists[k] = {waist.x, waist.y, waist.z, robe.hem_yaw}
			fs_params.robe_fx[k] = {robe.flutter, robe.death_t, 0, 0}

			// The cast orb, held out along the aim so a glance says both what
			// is coming and who it is coming for. Where a wisp is pointing is
			// the only thing about it that carries down a lane, so the orb
			// rides the look direction rather than sitting on the body.
			code := spell_type_code(remote.channel_spell)
			if code > 0 && remote.channel_frac > 0.01 {
				aim := camera_forward(yaw, remote.display_state.pitch)
				orb := cast_orb_pos(pos, yaw, aim, scale)
				fs_params.wisp_cast[k] = {orb.x, orb.y, orb.z, code}
				fs_params.wisp_aim[k] = {aim.x, aim.y, aim.z, clampf(remote.channel_frac, 0, 1)}
				r.orbs[ids[k]] = {orb.x, orb.y, orb.z, 1}
			}
		}
		// Wisps too far away to draw are not simulated either; their cloth
		// starts at rest when they come back into view rather than from stale
		// state.
		for k in take..<n {
			r.robes[ids[k]].settled = false
		}
	}

	for i in 0..<min(world.projectile_count, MAX_SNAPSHOT_PROJECTILES) {
		cp := &world.projectiles[i]
		pos := client_projectile_pos(cp, world.local_time)
		radius := clampf(cp.snap.radius, 0.05, 0.95)
		fs_params.projectiles[i] = {pos.x, pos.y, pos.z, spell_type_code(cp.snap.spell_id) + radius}
		fs_params.proj_vel[i] = {cp.snap.vel.x, cp.snap.vel.y, cp.snap.vel.z, 0}
	}

	for i in 0..<MAX_CLIENT_IMPACTS {
		im := &world.impacts[i]
		if !im.live {
			continue
		}
		fs_params.impacts[i] = {im.pos.x, im.pos.y, im.pos.z, spell_type_code(im.spell) + clampf(im.age, 0.01, 0.99)}
	}

	for i in 0..<MAX_CLIENT_STRIKES {
		s := &world.strikes[i]
		if !s.live {
			continue
		}
		fs_params.lightning[i] = {s.pos.x, s.pos.y, s.pos.z, clampf(s.life, 0.01, 1)}
	}

	if client_world_beams_current(world) {
		for i in 0..<world.beam_count {
			b := &world.beams[i]
			from: vec3
			to := b.end
			on_body := b.hit
			// The snapshot says which beam this is; a byte off the wire that is
			// not a spell falls back to the one beam everyone can see.
			def := &SPELL_DEFS[spell_valid(b.spell_id) ? b.spell_id : .Thunderbolt]
			if b.owner_id == world.local_entity_id {
				if !playing || dead > 0.5 {
					continue
				}
				// Leaves the hand orb and lands where the crosshair says, traced
				// this frame the way the server will trace it.
				from = {fs_params.hand_pos.x, fs_params.hand_pos.y, fs_params.hand_pos.z}
				trace_eye := base_pos + vec3{0, 0, PLAYER_EYE_M}
				look := camera_forward(gc.view_yaw, gc.view_pitch)
				to, on_body = client_world_beam_end(world, def, trace_eye, look)
			} else {
				remote := &world.remote_entities[int(b.owner_id)]
				if !remote.active {
					continue
				}
				// Out of the orb in their hand, the same one the wind-up
				// spells gather in. A beam owner too far away to be drawn as a
				// wisp has no orb this frame, so the chest stands in.
				orb := r.orbs[int(b.owner_id)]
				if orb.w > 0.5 {
					from = {orb.x, orb.y, orb.z}
				} else {
					from = remote.display_state.pos + vec3{0, 0, CHARACTER_HEIGHT_M * 0.55}
				}
			}
			fs_params.beams[i] = {from.x, from.y, from.z, spell_type_code(def.id)}
			fs_params.beam_ends[i] = {to.x, to.y, to.z, on_body ? 1 : 0}
			// Chains arc to bodies (players or minions), so they follow the
			// interpolated remotes or current minion snapshot positions.
			for c in 0..<min(int(b.chain_count), BEAM_MAX_CHAINS) {
				minion_id := b.chain_minion_ids[c]
				if minion_id > 0 {
					for mi in 0..<world.minion_count {
						m := &world.minions[mi]
						if m.id == minion_id && m.present {
							p := m.pos + vec3{0, 0, MINION_HEIGHT_M * 0.5}
							fs_params.beam_chains[i * BEAM_MAX_CHAINS + c] = {p.x, p.y, p.z, 1}
							break
						}
					}
					continue
				}
				eid := int(b.chains[c])
				if eid <= 0 || eid >= MAX_ENTITIES {
					continue
				}
				target := &world.remote_entities[eid]
				if !target.active {
					continue
				}
				p := target.display_state.pos + vec3{0, 0, CHARACTER_HEIGHT_M * 0.5}
				fs_params.beam_chains[i * BEAM_MAX_CHAINS + c] = {p.x, p.y, p.z, 1}
			}
		}
	}

	// --- Draw -----------------------------------------------------------------
	client_renderer_overlay(r, gc)

	sg.begin_pass({action = r.pass_action, swapchain = sglue.swapchain()})
	sg.apply_pipeline(r.pip)
	sg.apply_bindings(r.bind)
	sg.apply_uniforms(UB_vs_params, {ptr = &vs_params, size = size_of(vs_params)})
	sg.apply_uniforms(UB_fs_params, {ptr = &fs_params, size = size_of(fs_params)})
	sg.draw(0, 3, 1)
	sdtx.draw()
	sg.end_pass()
	sg.commit()

	r.frame_ms = f32(time.duration_milliseconds(time.tick_since(t0)))
	r.fps_accum += sapp.frame_duration()
	r.fps_presents += 1
	if r.fps_accum >= 0.5 {
		r.last_fps = f32(r.fps_presents) / f32(r.fps_accum)
		r.fps_accum = 0
		r.fps_presents = 0
	}
	r.perf_accum += sapp.frame_duration()
	r.perf_frames += 1
	if r.perf_accum >= 5.0 {
		wisps := 0
		for i in 0..<16 {
			if fs_params.wisps[i].w > 0.5 {
				wisps += 1
			}
		}
		fmt.printf("[Perf] %.0f fps avg over %.0fs (%d wisps, %d projectiles, %dx%d)\n",
			f64(r.perf_frames) / r.perf_accum, r.perf_accum, wisps, world.projectile_count, sapp.width(), sapp.height())
		r.perf_accum = 0
		r.perf_frames = 0
	}
}

// ---------------------------------------------------------------------------
// HUD

@(private = "file")
sdtx_color :: proc(c: vec3) {
	sdtx.color3f(c.x, c.y, c.z)
}

@(private = "file")
sdtx_str :: proc(text: string) {
	sdtx.puts(strings.clone_to_cstring(text, context.temp_allocator))
}

@(private = "file")
hud_center_text :: proc(cols: f32, row: f32, text: string) {
	col := cols * 0.5 - f32(len(text)) * 0.5
	sdtx.pos(max(col, 0), row)
	sdtx_str(text)
}

client_renderer_overlay :: proc(r: ^Client_Renderer, gc: ^Game_Client) {
	w := sapp.widthf() * SDTX_CANVAS_SCALE
	h := sapp.heightf() * SDTX_CANVAS_SCALE
	cols := w / SDTX_CHAR_PX - 2 * SDTX_ORIGIN_CELLS
	rows := h / SDTX_CHAR_PX - 2 * SDTX_ORIGIN_CELLS
	sdtx.canvas(w, h)
	sdtx.origin(SDTX_ORIGIN_CELLS, SDTX_ORIGIN_CELLS)
	sdtx.home()
	sdtx.font(0)

	world := &gc.client_world

	// Stats line (always)
	sdtx.color3f(0.78, 0.76, 0.70)
	sdtx.printf("NEXUS ARENA  %.0f fps  %.1f ms", r.last_fps, r.frame_ms)
	if gc.phase == .Playing || gc.phase == .In_Menu {
		rate, total := client_prediction_stats(&world.prediction)
		_, _, since := network_client_stats(&gc.network)
		sdtx.color3f(0.55, 0.53, 0.50)
		sdtx.printf("   corr %.1f%% (%d)  last pkt %.0fms  tick %d", rate * 100, total, since, world.client_tick)
	}
	sdtx.puts("\n")

	switch gc.phase {
	case .Connecting:
		hud_lobby_frame(gc, cols, rows, "SEARCHING FOR SERVER...")
	case .Team_Select:
		hud_lobby_frame(gc, cols, rows, "CHOOSE YOUR TEAM")
	case .Joining:
		hud_lobby_frame(gc, cols, rows, fmt.tprintf("JOINING %s...", team_name(gc.chosen_team)))
	case .Playing:
		hud_playing(gc, cols, rows)
	case .In_Menu:
		hud_in_game_menu(gc, cols, rows)
	}
}

@(private = "file")
hud_lobby_frame :: proc(gc: ^Game_Client, cols, rows: f32, title: string) {
	sdtx.color3f(0.95, 0.93, 0.86)
	hud_center_text(cols, rows * 0.28, "N E X U S   A R E N A")
	sdtx.color3f(0.62, 0.60, 0.68)
	hud_center_text(cols, rows * 0.28 + 1, "three teams. seven pylons of ore. one golden tower.")

	sdtx.color3f(0.90, 0.88, 0.80)
	hud_center_text(cols, rows * 0.42, title)

	if gc.phase == .Team_Select || gc.phase == .Joining {
		sdtx.color3f(0.62, 0.60, 0.56)
		hud_center_text(cols, rows * 0.42 + 1.5, "your name")
		name := player_name_display(&gc.player_name, 0, false)
		if gc.player_name.len == 0 {
			name = "(unnamed)"
		}
		if gc.name_editing {
			sdtx.color3f(0.98, 0.96, 0.88)
			hud_center_text(cols, rows * 0.42 + 2.5, fmt.tprintf("%s_", name))
		} else {
			sdtx.color3f(0.72, 0.70, 0.64)
			hud_center_text(cols, rows * 0.42 + 2.5, name)
		}

		base_row := rows * 0.42 + 5
		for i in 0..<TEAM_COUNT {
			team := team_from_index(i)
			allowed := client_team_allowed(gc, team)
			humans := int(gc.lobby.humans[i])
			bots := int(gc.lobby.bots[i])
			col := team_color(team)
			if !allowed {
				col = col * 0.35 + vec3{0.2, 0.2, 0.2}
			}
			sdtx_color(col)
			line := fmt.tprintf("[%d]  %-8s  %d players  %d bots%s", i + 1, team_name(team), humans, bots,
				allowed ? "" : "   (most populated - locked)")
			hud_center_text(cols, base_row + f32(i) * 2, line)
		}
		sdtx.color3f(0.55, 0.53, 0.50)
		hint := "press 1, 2 or 3 to join  -  Enter to rename  -  you cannot join the most populated team"
		if gc.name_editing {
			hint = "type a name, Enter when you are done  -  a blank name gets you one"
		}
		hud_center_text(cols, base_row + 7, hint)
		if gc.reject_timer > 0 {
			sdtx.color3f(1.0, 0.55, 0.45)
			msg := "that team is full or the most populated - pick another"
			#partial switch gc.reject_reason {
			case .Server_Full:  msg = "server is full"
			case .Invalid_Team: msg = "invalid team"
			}
			hud_center_text(cols, base_row + 9, msg)
		}
	}

	sdtx.color3f(0.42, 0.40, 0.38)
	hud_center_text(cols, rows - 1, fmt.tprintf("WASD move  /  Shift sprint  /  Space jump  /  1-%d spells  /  LMB cast  /  Esc unlock mouse", HOTBAR_SLOTS))
}

@(private = "file")
hud_in_game_menu :: proc(gc: ^Game_Client, cols, rows: f32) {
	// Draw a simple pause menu
	sdtx.color3f(0.95, 0.93, 0.86)
	hud_center_text(cols, rows * 0.25, "GAME MENU")
	
	sdtx.color3f(0.70, 0.68, 0.65)
	hud_center_text(cols, rows * 0.25 + 2, "Press ESC to resume")

	base_row := rows * 0.40
	
	// Team join options
	if gc.have_lobby {
		for i in 0..<TEAM_COUNT {
			team := team_from_index(i)
			allowed := client_team_allowed(gc, team)
			humans := int(gc.lobby.humans[i])
			bots := int(gc.lobby.bots[i])
			col := team_color(team)
			if !allowed {
				col = col * 0.35 + vec3{0.2, 0.2, 0.2}
			}
			sdtx_color(col)
			
			current_marker := ""
			if team == gc.client_world.local_team {
				current_marker = "  (current)"
			}
			
			line := fmt.tprintf("[%d]  Join %s  -  %d players  %d bots%s%s", 
				i + 1, team_name(team), humans, bots,
				allowed ? "" : "  (locked)",
				current_marker)
			hud_center_text(cols, base_row + f32(i) * 2, line)
		}
	} else {
		// Fallback if no lobby data
		for i in 0..<TEAM_COUNT {
			team := team_from_index(i)
			col := team_color(team)
			sdtx_color(col)
			line := fmt.tprintf("[%d]  Join %s", i + 1, team_name(team))
			hud_center_text(cols, base_row + f32(i) * 2, line)
		}
	}

	// Spectate option
	sdtx.color3f(0.70, 0.70, 0.70)
	spectate_marker := ""
	if gc.is_spectating {
		spectate_marker = "  (current)"
	}
	hud_center_text(cols, base_row + f32(TEAM_COUNT) * 2, fmt.tprintf("[4]  Spectate%s", spectate_marker))

	sdtx.color3f(0.50, 0.48, 0.45)
	hud_center_text(cols, base_row + f32(TEAM_COUNT) * 2 + 3, "Choose an option or press ESC to return to the game")
}

@(private = "file")
hud_playing :: proc(gc: ^Game_Client, cols, rows: f32) {
	world := &gc.client_world
	pred := &world.prediction
	local := pred.predicted_char
	gs := &world.game_state

	// Spectator mode: show simplified HUD
	if gc.is_spectating {
		sdtx.color3f(0.70, 0.70, 0.70)
		hud_center_text(cols, rows * 0.1, "SPECTATING")
		sdtx.color3f(0.50, 0.50, 0.50)
		hud_center_text(cols, rows * 0.1 + 1, "Press ESC to open menu and join a team")
		
		// Show match status
		if world.have_game_state {
			state := Match_State(gs.match_state)
			status := ""
			switch state {
			case .Waiting:
				status = fmt.tprintf("WARMUP  %d", int(max(WARMUP_DURATION - gs.match_time, 0)))
			case .Active:
				m := int(gs.match_time) / 60
				s := int(gs.match_time) % 60
				status = fmt.tprintf("%02d:%02d", m, s)
			case .Ended:
				if Match_Result(gs.match_result) == .Team_Wins {
					status = fmt.tprintf("%s WINS", team_name(Team_ID(gs.winner)))
				} else {
					status = "DRAW"
				}
			}
			sdtx.color3f(0.80, 0.78, 0.75)
			hud_center_text(cols, rows * 0.15, status)
			
			// Scores
			line_w: f32 = 0
			parts: [TEAM_COUNT]string
			for i in 0..<TEAM_COUNT {
				parts[i] = fmt.tprintf("%s %4.0f", team_name(team_from_index(i)), gs.essence[i])
				line_w += f32(len(parts[i]))
			}
			line_w += 3 * 2
			col := cols * 0.5 - line_w * 0.5
			sdtx.pos(col, rows * 0.15 + 1)
			for i in 0..<TEAM_COUNT {
				team := team_from_index(i)
				sdtx_color(team_color(team))
				sdtx_str(parts[i])
				if i < TEAM_COUNT - 1 {
					sdtx.color3f(0.5, 0.5, 0.5)
					sdtx.puts(" /")
				}
			}
		}
		return
	}

	// --- Match header (top center) --------------------------------------------
	if world.have_game_state {
		state := Match_State(gs.match_state)
		status := ""
		switch state {
		case .Waiting:
			status = fmt.tprintf("WARMUP  %d", int(max(WARMUP_DURATION - gs.match_time, 0)))
		case .Active:
			m := int(gs.match_time) / 60
			s := int(gs.match_time) % 60
			status = fmt.tprintf("%02d:%02d", m, s)
		case .Ended:
			if Match_Result(gs.match_result) == .Team_Wins {
				status = fmt.tprintf("%s WINS", team_name(Team_ID(gs.winner)))
			} else {
				status = "DRAW"
			}
		}
		sdtx.color3f(0.95, 0.93, 0.86)
		hud_center_text(cols, 1, status)

		// Scores
		line_w: f32 = 0
		parts: [TEAM_COUNT]string
		for i in 0..<TEAM_COUNT {
			parts[i] = fmt.tprintf("%s %4.0f", team_name(team_from_index(i)), gs.essence[i])
			line_w += f32(len(parts[i]))
		}
		line_w += 3 * 2
		col := cols * 0.5 - line_w * 0.5
		sdtx.pos(col, 2)
		for i in 0..<TEAM_COUNT {
			team := team_from_index(i)
			sdtx_color(team_color(team))
			if team == world.local_team {
				sdtx.puts(">")
			} else {
				sdtx.puts(" ")
			}
			sdtx_str(parts[i])
			if i < TEAM_COUNT - 1 {
				sdtx.color3f(0.5, 0.5, 0.5)
				sdtx.puts(" /")
			}
		}

		// The round, once the golden pylon is down: whose rock is going back
		// into the stump. This replaces the pylon row it sits on, because from
		// the moment the centre opens it is the only line that decides anything.
		if gs.centre_open {
			share_w := f32(TEAM_COUNT) * 11
			sdtx.pos(cols * 0.5 - share_w * 0.5, 3)
			sdtx.color3f(0.95, 0.88, 0.55)
			sdtx.puts("CENTRE ")
			for i in 0..<TEAM_COUNT {
				sdtx_color(team_color(team_from_index(i)))
				sdtx.printf("%s %3d%% ", team_name(team_from_index(i)), int(f32(gs.centre_share[i]) / 255.0 * 100))
			}
		} else {
			// Towers: how much of each tower is still standing. G is the golden
			// one in the centre, then the near-lane towers and the far ones.
			sdtx.pos(cols * 0.5 - f32(MAX_PYLONS) * 4.0, 3)
			for i in 0..<MAX_PYLONS {
				t := &world.towers.towers[i]
				sdtx_color(ore_color(t.ore))
				label := i == 0 ? "G" : fmt.tprintf("%d", i)
				sdtx.printf("[%s %3d]", label, int(gs.towers[i].intact * 100))
				sdtx.puts(" ")
			}
		}

		// The wallet: what the local team has banked, one column per ore.
		// Enemy ore buys extra pushers that walk the *other* rival's lane, so a
		// stack of Ember on Verdant's HUD is a Tide problem, not an Ember one.
		if world.local_team != .None && world.local_team != .Spectator {
			w := &gs.wallets[team_index(world.local_team)]
			line := f32(ORE_COUNT) * 9
			sdtx.pos(cols * 0.5 - line * 0.5, 4)
			for k in 0..<ORE_COUNT {
				kind := ore_from_index(k)
				sdtx_color(ore_color(kind))
				sdtx.printf("%-7s %3d ", ore_name(kind), int(w[k]))
			}
		}
	}

	// --- Vitals (bottom left) --------------------------------------------------
	hud_y := rows - 8
	sdtx.pos(0, hud_y)
	sdtx.color3f(1.0, 0.42, 0.36)
	sdtx.puts("HP ")
	draw_bar(local.health, HEALTH_MAX, 22)
	sdtx.printf(" %3.0f", local.health)

	sdtx.pos(0, hud_y + 1)
	sdtx.color3f(0.45, 0.66, 1.0)
	sdtx.puts("MP ")
	draw_bar(local.mana, MANA_MAX, 22)
	sdtx.printf(" %3.0f", local.mana)

	sdtx.pos(0, hud_y + 2)
	sdtx.color3f(0.55, 0.9, 0.5)
	sdtx.puts("ST ")
	draw_bar(local.stamina, STAMINA_MAX, 22)
	sdtx.printf(" %3.0f", local.stamina)

	if local.slow_ticks > 0 {
		sdtx.pos(0, hud_y + 3)
		sdtx.color3f(0.5, 0.92, 1.0)
		sdtx.puts("SLOWED")
	}

	// --- Hotbar (bottom center) ------------------------------------------------
	slot_w: f32 = 14
	start := cols * 0.5 - slot_w * f32(HOTBAR_SLOTS) * 0.5
	_, have_strike_target := client_world_strike_target(world)
	for i in 0..<HOTBAR_SLOTS {
		spell := HOTBAR[i]
		def := &SPELL_DEFS[spell]
		cd := gc.cooldowns[spell]
		selected := i == gc.selected_slot
		ready := spell_castable(spell, local, cd)
		col := start + f32(i) * slot_w

		sdtx.pos(col, rows - 3)
		if selected {
			sdtx.color3f(1.0, 0.95, 0.6)
			sdtx.printf("[%d] %-8s", i + 1, def.short_name)
		} else {
			sdtx.color3f(0.6, 0.58, 0.54)
			sdtx.printf(" %d  %-8s", i + 1, def.short_name)
		}

		sdtx.pos(col, rows - 2)
		if spell == gc.charging_spell && def.payload == .Beam {
			// A beam has no wind-up to show; the bar crackles while the server
			// keeps it lit and the mana drain, drawn to its right, is the
			// thing to watch.
			_, lit := client_world_local_beam(world)
			if !lit {
				sdtx.color3f(0.45, 0.5, 0.6)
			} else {
				sdtx.color3f(0.75, 0.88, 1.0)
			}
			phase := int(world.local_time * 24)
			for k in 0..<10 {
				sdtx.putc((k + phase) % 3 == 0 ? '~' : '#')
			}
			sdtx.printf(" -%.0f/s", def.beam_mana_per_sec)
		} else if spell == gc.charging_spell {
			// Wind-up: dim early, bright once the bar is well on its way.
			// Letting go does not stop this — an early release still fills.
			charge := spell_charge_frac(def, gc.charge_accum)
			if charge < SPELL_MIN_CHARGE {
				sdtx.color3f(0.45, 0.5, 0.6)
			} else {
				sdtx.color3f(0.3, 0.85, 1.0)
			}
			filled := int(charge * 10)
			for k in 0..<10 {
				sdtx.putc(k < filled ? '#' : '.')
			}
			sdtx.printf(" %3.0f%%", charge * 100)
		} else if cd > 0 {
			sdtx.color3f(0.45, 0.45, 0.5)
			frac := 1.0 - cd / def.cooldown_sec
			filled := int(frac * 10)
			for k in 0..<10 {
				sdtx.putc(k < filled ? '=' : '.')
			}
			sdtx.printf(" %.1f", cd)
		} else if def.payload == .Heal && !client_heal_has_work(world, local) {
			// Nothing to mend: say so rather than blaming the mana.
			sdtx.color3f(0.5, 0.7, 0.55)
			sdtx.puts("at full hp")
		} else if !ready {
			sdtx.color3f(0.45, 0.55, 0.85)
			sdtx.printf("need %.0f mp", def.mana_cost)
		} else if def.payload == .Strike && !have_strike_target {
			// Affordable and off cooldown, but nobody under the crosshair.
			sdtx.color3f(0.6, 0.6, 0.65)
			sdtx.puts("no target")
		} else {
			sdtx.color3f(0.5, 0.75, 0.55)
			sdtx.puts("==========")
		}
	}

	// --- Center ----------------------------------------------------------------
	cx := cols * 0.5
	cy := rows * 0.5
	if local.dead {
		sdtx.color3f(1.0, 0.5, 0.45)
		hud_center_text(cols, cy - 1, "YOU WERE UNMADE")
		sdtx.color3f(0.8, 0.78, 0.72)
		hud_center_text(cols, cy + 1, fmt.tprintf("respawning in %.0f", max(local.respawn_timer, 0)))
	} else {
		if world.hit_marker > 0.05 {
			sdtx.color3f(1.0, 0.9, 0.5)
			sdtx.pos(cx - 1, cy - 1); sdtx.puts("\\ /")
			sdtx.pos(cx - 1, cy + 1); sdtx.puts("/ \\")
		}
		sdtx.color3f(0.85, 0.83, 0.78)
		sdtx.pos(cx, cy)
		sdtx.puts("+")
		hud_target_panel(world, cols, cy + 2)
	}

	if !sapp.mouse_locked() {
		sdtx.color3f(0.95, 0.9, 0.7)
		hud_center_text(cols, cy + 4, "click to capture the mouse")
	}

	if world.have_game_state && Match_State(gs.match_state) == .Waiting {
		sdtx.color3f(0.7, 0.68, 0.62)
		hud_center_text(cols, 6, "walk over the ore to bank it - your own rock thickens the next wave")
		hud_center_text(cols, 7, "bring the golden tower down, then build it back: most rock in the stump wins")
	}

	// Taking a tower does not open a push; it turns the owner's waves into a
	// repair crew. That is the one rule of this mode nobody guesses, so it is
	// said out loud the first time a friendly tower is missing enough rock
	// that the next wave will hop it, and again once the centre is the prize.
	if world.have_game_state && Match_State(gs.match_state) == .Active {
		if gs.centre_open {
			sdtx.color3f(0.95, 0.88, 0.55)
			hud_center_text(cols, 6, "the centre is open - your waves are rebuilding it, most rock laid wins")
		} else if world.local_team != .None && world.local_team != .Spectator {
			own := team_index(world.local_team)
			near := own + 1
			far := own + 4
			if gs.towers[near].intact < PYLON_REBUILD_FRAC || gs.towers[far].intact < PYLON_REBUILD_FRAC {
				sdtx.color3f(0.85, 0.78, 0.55)
				hud_center_text(cols, 6, "your waves are rebuilding the tower - flattening a lane stalls that team")
			}
		}
	}

	hud_combat_log(world, cols, rows)
	if input.key_tab {
		hud_scoreboard(world, cols, rows)
	}
}

// Recent combat, bottom right, out of the way of the crosshair, the vitals and
// the hotbar. Newest at the bottom, each line holding at full brightness and
// then fading rather than vanishing mid-read.
@(private = "file")
hud_combat_log :: proc(world: ^Client_World, cols, rows: f32) {
	// Oldest first, so the list reads downward the way a log should.
	order: [MAX_COMBAT_LOG_LINES]int
	count := 0
	for i in 0..<MAX_COMBAT_LOG_LINES {
		if !world.combat_log[i].live {
			continue
		}
		pos := count
		for pos > 0 && world.combat_log[order[pos - 1]].age < world.combat_log[i].age {
			order[pos] = order[pos - 1]
			pos -= 1
		}
		order[pos] = i
		count += 1
	}

	left := max(cols - 40, 0)
	top := rows - 6 - f32(count)
	for k in 0..<count {
		line := &world.combat_log[order[k]]
		other := client_world_name(world, line.other_id)
		spell := SPELL_DEFS[line.spell_id].short_name

		text: string
		col: vec3
		switch line.event_type {
		case .Damage_Dealt:
			text = fmt.tprintf("you hit %s for %d (%s)", other, line.damage, spell)
			col = {1.0, 0.82, 0.35}
		case .Damage_Taken:
			text = fmt.tprintf("%s hit you for %d (%s)", other, line.damage, spell)
			col = {1.0, 0.45, 0.35}
		case .Kill:
			text = fmt.tprintf("you unmade %s", other)
			col = {0.55, 1.0, 0.45}
		case .Death:
			text = fmt.tprintf("%s unmade you", other)
			col = {1.0, 0.35, 0.35}
		}

		fade := clampf((COMBAT_LOG_HOLD_SEC + COMBAT_LOG_FADE_SEC - line.age) / COMBAT_LOG_FADE_SEC, 0, 1)
		sdtx_color(col * fade)
		sdtx.pos(left, top + f32(k))
		sdtx_str(text)
	}
}

// Hold Tab for the whole match: everyone the roster knows about, grouped by
// team. The roster is not interest-managed, so this is the real scoreline and
// not just the players who happen to be nearby.
@(private = "file")
hud_scoreboard :: proc(world: ^Client_World, cols, rows: f32) {
	ids: [MAX_ENTITIES]Entity_ID
	count := 0
	for i in 1..<MAX_ENTITIES {
		if world.roster[i].present {
			ids[count] = Entity_ID(i)
			count += 1
		}
	}
	if count == 0 {
		return
	}

	// Team first so the groups hold together, then kills, then fewest deaths.
	for i in 1..<count {
		id := ids[i]
		a := &world.roster[id]
		j := i
		for j > 0 {
			b := &world.roster[ids[j - 1]]
			better := int(a.team) < int(b.team) ||
				(a.team == b.team && a.stats.kills > b.stats.kills) ||
				(a.team == b.team && a.stats.kills == b.stats.kills && a.stats.deaths < b.stats.deaths)
			if !better {
				break
			}
			ids[j] = ids[j - 1]
			j -= 1
		}
		ids[j] = id
	}

	width: f32 = 46
	height := f32(count + TEAM_COUNT + 3)
	left := max(cols * 0.5 - width * 0.5, 0)
	top := max(rows * 0.5 - height * 0.5, 4)

	sdtx.color3f(0.95, 0.93, 0.86)
	hud_center_text(cols, top, "SCOREBOARD")
	sdtx.color3f(0.55, 0.53, 0.50)
	sdtx.pos(left, top + 1)
	sdtx.printf("%-18s %4s %4s %7s %7s", "name", "k", "d", "dealt", "taken")

	row := top + 2
	last_team := Team_ID.None
	for k in 0..<count {
		id := ids[k]
		slot := &world.roster[id]
		if slot.team != last_team {
			last_team = slot.team
			sdtx_color(team_color(slot.team) * 0.8)
			sdtx.pos(left, row)
			sdtx_str(team_name(slot.team))
			row += 1
		}
		if id == world.local_entity_id {
			sdtx.color3f(1.0, 0.95, 0.6)
		} else if slot.is_bot {
			sdtx.color3f(0.62, 0.60, 0.56)
		} else {
			sdtx.color3f(0.86, 0.84, 0.79)
		}
		sdtx.pos(left, row)
		sdtx.printf("%-18s %4d %4d %7.0f %7.0f",
			client_world_name(world, id),
			slot.stats.kills, slot.stats.deaths,
			slot.stats.damage_dealt, slot.stats.damage_taken)
		row += 1
	}
}

// Who the crosshair is holding, under the crosshair: name in team colour over a
// health bar. Nothing is drawn when there is no target, so the centre of the
// screen stays clean while the player is just moving around.
@(private = "file")
hud_target_panel :: proc(world: ^Client_World, cols: f32, row: f32) {
	if world.target_id == INVALID_ENTITY {
		return
	}
	remote := &world.remote_entities[world.target_id]

	sdtx_color(team_color(remote.team))
	hud_center_text(cols, row, client_world_name(world, remote.id))

	hp := remote.display_state.health
	frac := hp / HEALTH_MAX
	if frac > 0.6 {
		sdtx.color3f(0.5, 0.9, 0.5)
	} else if frac > 0.3 {
		sdtx.color3f(1.0, 0.8, 0.3)
	} else {
		sdtx.color3f(1.0, 0.4, 0.3)
	}
	sdtx.pos(cols * 0.5 - 10, row + 1)  // 16-cell bar plus " 100" centres at -10
	draw_bar(hp, HEALTH_MAX, 14)
	sdtx.printf(" %3.0f", hp)
}

draw_bar :: proc(value: f32, max_value: f32, width: int) {
	filled := int((value / max_value) * f32(width) + 0.5)
	filled = clamp(filled, 0, width)
	sdtx.putc('[')
	for i in 0..<filled {
		sdtx.putc('=')
	}
	for i in filled..<width {
		sdtx.putc(' ')
	}
	sdtx.putc(']')
}
