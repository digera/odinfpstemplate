package main

// Spell system for Phase 3 combat

// Resource pools
HEALTH_MAX :: f32(100)
MANA_MAX :: f32(100)
STAMINA_MAX :: f32(100)
STAMINA_REGEN_PER_SEC :: f32(25)  // 4 seconds to full regen
MANA_REGEN_PER_SEC :: f32(10)     // 10 seconds to full regen

// Spell IDs
Spell_ID :: enum u8 {
	None = 0,
	
	// Arcane
	Arcane_Missile = 1,    // Fast projectile
	Arcane_Orb = 2,        // Slow heavy AoE
	Blink = 3,             // Short directional phase
	
	// Fire
	Flame_Wave = 4,        // Cone pushback
	Magma_Burst = 5,       // Delayed ground explosion
	
	// Frost
	Frost_Shard = 6,       // Projectile + slow debuff
	Ice_Wall = 7,          // Temporary barrier
	
	// Life/Holy
	Purifying_Beam = 8,    // Channel heal/burn
	Ward_Sphere = 9,       // Blocks projectiles
}

// Spell definition
Spell_Def :: struct {
	id:           Spell_ID,
	name:         string,
	mana_cost:    f32,
	cooldown_sec: f32,
	cast_time:    f32,      // 0 = instant
	
	// Payload type
	payload:      Spell_Payload_Type,
	
	// Projectile data (if projectile type)
	proj_speed:   f32,      // m/s
	proj_lifetime: f32,     // seconds
	proj_radius:  f32,      // collision radius
	proj_gravity: bool,     // affected by gravity
	
	// Damage/heal
	damage:       f32,
	healing:      f32,
	
	// AoE
	aoe_radius:   f32,
	
	// Effects
	knockback:    f32,      // meters/sec impulse
	slow_factor:  f32,      // 0.5 = half speed
	slow_duration: f32,     // seconds
	
	// Hitscan/beam
	beam_range:   f32,      // max range for hitscan
	beam_width:   f32,      // cylinder radius
}

Spell_Payload_Type :: enum u8 {
	None = 0,
	Projectile,      // Physical projectile
	Hitscan,         // Instant raycast
	Beam_Channel,    // Continuous beam (not impl Phase 3)
	Teleport,        // Movement (Blink)
	AoE_Instant,     // Instant area damage
}

// Spell book (global definitions)
SPELL_DEFS := [Spell_ID]Spell_Def{
	.None = {},
	
	.Arcane_Missile = {
		id           = .Arcane_Missile,
		name         = "Arcane Missile",
		mana_cost    = 15,
		cooldown_sec = 1.0,
		cast_time    = 0,
		payload      = .Projectile,
		proj_speed   = 35,      // Fast
		proj_lifetime = 3.0,
		proj_radius  = 0.15,
		proj_gravity = false,
		damage       = 25,
	},
	
	.Arcane_Orb = {
		id           = .Arcane_Orb,
		name         = "Arcane Orb",
		mana_cost    = 40,
		cooldown_sec = 4.0,
		cast_time    = 0,
		payload      = .Projectile,
		proj_speed   = 12,      // Slow
		proj_lifetime = 5.0,
		proj_radius  = 0.4,     // Large
		proj_gravity = false,
		damage       = 60,
		aoe_radius   = 3.0,     // AoE explosion
		knockback    = 8.0,
	},
	
	.Blink = {
		id           = .Blink,
		name         = "Blink",
		mana_cost    = 25,
		cooldown_sec = 8.0,
		cast_time    = 0,
		payload      = .Teleport,
		beam_range   = 10,      // Blink distance
	},
	
	.Frost_Shard = {
		id           = .Frost_Shard,
		name         = "Frost Shard",
		mana_cost    = 20,
		cooldown_sec = 2.0,
		cast_time    = 0,
		payload      = .Projectile,
		proj_speed   = 25,
		proj_lifetime = 4.0,
		proj_radius  = 0.2,
		proj_gravity = false,
		damage       = 30,
		slow_factor  = 0.5,     // 50% slow
		slow_duration = 2.0,
	},
	
	// Stubs for remaining spells
	.Flame_Wave = {
		id           = .Flame_Wave,
		name         = "Flame Wave",
		mana_cost    = 30,
		cooldown_sec = 6.0,
		payload      = .None,  // TODO Phase 3.5
	},
	
	.Magma_Burst = {
		id           = .Magma_Burst,
		name         = "Magma Burst",
		mana_cost    = 35,
		cooldown_sec = 10.0,
		payload      = .None,  // TODO Phase 3.5
	},
	
	.Ice_Wall = {
		id           = .Ice_Wall,
		name         = "Ice Wall",
		mana_cost    = 40,
		cooldown_sec = 15.0,
		payload      = .None,  // TODO Phase 3.5
	},
	
	.Purifying_Beam = {
		id           = .Purifying_Beam,
		name         = "Purifying Beam",
		mana_cost    = 50,
		cooldown_sec = 12.0,
		payload      = .Beam_Channel,  // TODO Phase 3.5
		beam_range   = 20,
		beam_width   = 0.5,
	},
	
	.Ward_Sphere = {
		id           = .Ward_Sphere,
		name         = "Ward Sphere",
		mana_cost    = 45,
		cooldown_sec = 20.0,
		payload      = .None,  // TODO Phase 3.5
	},
}

// Entity spell state
Entity_Spell_State :: struct {
	cooldowns: [Spell_ID]f32,  // Remaining cooldown time for each spell
}

// Spell cast request
Spell_Cast :: struct {
	caster_id: Entity_ID,
	spell_id:  Spell_ID,
	origin:    vec3,
	direction: vec3,  // Normalized
	tick:      u32,
}
