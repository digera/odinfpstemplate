# Nexus Arena - Combat Tracers & HUD

## Overview
Graphical client now renders in-flight projectiles and displays a combat HUD showing Health, Mana, Stamina, and active spell selection.

## Implementation

### 1. Projectile Rendering (Tracers)

**Location:** `shaders/scene.glsl`, `src/client_renderer.odin`

**Shader Changes:**
- Added `projectiles: [16]vec4` array to fragment shader uniforms
- Format: `xyz` = world position, `w` = radius * spell_type_code
- Spell type codes: 1=Arcane_Missile, 2=Arcane_Orb, 3=Blink, 4=Frost_Shard
- New `projectile_trace` function performs sphere raycasting for all active projectiles
- Material type `MAT_PROJECTILE` (7) with spell-specific colors:
  - **Arcane Missile**: Purple `(0.82, 0.42, 0.92)`
  - **Arcane Orb**: Blue `(0.52, 0.62, 0.92)`
  - **Blink**: White `(0.92, 0.92, 0.98)`
  - **Frost Shard**: Cyan `(0.42, 0.82, 0.92)`
- Projectiles glow with Fresnel rim lighting effect

**Renderer Integration:**
```odin
// In client_renderer_draw, pack projectile data from Client_World
for i in 0..<min(client_world.projectile_count, 16) {
    proj := &client_world.projectiles[i]
    
    type_code: f32
    #partial switch proj.spell_id {
    case .Arcane_Missile: type_code = 1
    case .Arcane_Orb:     type_code = 2
    case .Blink:          type_code = 3
    case .Frost_Shard:    type_code = 4
    }
    
    fs_params.projectiles[i] = vec4{
        proj.pos.x, proj.pos.y, proj.pos.z,
        proj.radius * type_code,
    }
}
```

Projectiles are synced from server snapshots (Phase 3.5) and rendered every frame.

### 2. Combat HUD

**Location:** `src/client_renderer.odin` - `client_renderer_overlay` function

**Resource Bars:**
- **Health (HP)**: Red bar `[====================]` with numeric readout `100/100`
- **Mana (MP)**: Blue bar showing mana pool for spell casting
- **Stamina (ST)**: Green bar (for future sprint/dodge mechanics)

Values are synced from server snapshots via `Character_State.{health, mana, stamina}`.

**Spell Selection Display:**
```
Spells:
> 1: Arcane Missile   (selected, highlighted yellow)
  2: Arcane Orb
  3: Blink
  4: Frost Shard
```

- Selected spell highlighted in bright yellow
- Press keys 1-4 to select spell
- Hold LMB to cast selected spell along mouse-look aim

**Helper Function:**
```odin
draw_bar :: proc(value: f32, max_value: f32, width: int) {
    filled := int((value / max_value) * f32(width))
    sdtx.putc('[')
    for i in 0..<filled { sdtx.putc('=') }
    for i in filled..<width { sdtx.putc(' ') }
    sdtx.putc(']')
}
```

### 3. Input Wiring

**Location:** `src/input.odin`, `src/main_client.odin`

**Keybinds:**
- **1**: Select Arcane Missile
- **2**: Select Arcane Orb
- **3**: Select Blink
- **4**: Select Frost Shard
- **LMB (Hold)**: Cast selected spell

**Input Flow:**
1. `input.odin` captures key presses for 1-4 and sets `cast_N` flags
2. `main_client.odin` `client_handle_input` consumes cast flags to update `game_client.selected_spell`
3. When `input.held_left` is true, `input_state.cast_spell` is set to `selected_spell`
4. Cast intent sent to server in next input packet
5. Server validates and spawns projectile
6. Client receives projectile in snapshot and renders it

**Code:**
```odin
// In client_handle_input
if input_consume_cast(1) { client.selected_spell = .Arcane_Missile }
if input_consume_cast(2) { client.selected_spell = .Arcane_Orb }
if input_consume_cast(3) { client.selected_spell = .Blink }
if input_consume_cast(4) { client.selected_spell = .Frost_Shard }

if input.held_left {
    client.input_state.cast_spell = client.selected_spell
} else {
    client.input_state.cast_spell = .None
}
```

Aim direction comes from `input_state.yaw` and `input_state.pitch` (mouse-look).

## Build & Run

### Prerequisites
- X11 display and OpenGL (Linux desktop)
- Headless VM: requires Xvfb or SSH with X11 forwarding

### Build
```bash
./build_graphical_client.sh
```

### Run Server
```bash
./bin/server
```

### Run Graphical Client
```bash
./bin/nexus_client
```

**On VM without display:**
```bash
# Option 1: Xvfb virtual display
Xvfb :99 -screen 0 1024x768x24 &
DISPLAY=:99 ./bin/nexus_client

# Option 2: Document only (code still compiles)
# Visual verification must be done locally with a real display
```

## What You Should See

1. **Projectiles:**
   - In-flight spheres colored by spell type
   - Purple for Arcane Missile (fast)
   - Blue for Arcane Orb (slow, large)
   - Cyan for Frost Shard
   - Projectiles appear when server spawns them after cast validation

2. **Combat HUD (bottom-left):**
   - HP/MP/ST bars update from server state
   - Selected spell highlighted with `>` marker
   - Bars fill/empty in real-time as resources change

3. **Casting:**
   - Press 1-4 to select spell (HUD updates)
   - Hold LMB to cast (mana decreases, projectile spawns)
   - Cooldowns enforced server-side (Phase 3)

## Verification Limits

**VM Display Constraints:**
- This VM has no GPU or X11 display
- Build succeeds; code is complete
- **Visual verification requires local testing** with real hardware

**Headless Testing:**
- Server + combat test client can verify:
  - Projectile sync in snapshots
  - Resource deduction
  - Server-side hit registration
- See `test_combat_hardened.sh` for automated tests

## Code References

### Shader
- `shaders/scene.glsl:194-222` - `projectile_trace` function
- `shaders/scene.glsl:285-303` - Projectile material coloring

### Renderer
- `src/client_renderer.odin:161-187` - Projectile packing
- `src/client_renderer.odin:182-275` - Combat HUD overlay

### Input
- `src/input.odin:13-21` - Key/cast state
- `src/input.odin:155-179` - `input_consume_cast`
- `src/main_client.odin:185-205` - Spell selection & cast input

## Next Steps (Phase 4, not implemented)

Future enhancements:
- Cooldown timers in HUD (numeric or bar)
- Buff/debuff icons
- Hit indicators / damage numbers
- Team color coding for remote entities
- Minimap with Obelisk status (Nexus Dominion mode)

---

**Status:** ✅ Code-complete, builds successfully, visual verification pending local testing.
