# Technical Audit Fixes (Round 2)

All critical and "should fix" bugs from the second technical audit have been addressed.

## Critical Fixes (Blockers)

### 1. Entity wire size desync (50 vs 42) ✓
**Issue**: Serializer packed 42 bytes per entity but deserializer used a 50-byte bounds check.

**Fix**:
- Updated `ENTITY_SIZE :: 42` constant in `network.odin` with full breakdown comment:
  - id(4) + pos(12) + yaw(4) + pitch(4) + vel_z(4) + on_ground(1) + health(4) + mana(4) + stamina(4) + team(1) = **42 bytes**
- Updated deserialize bounds check to use 42 bytes in `network_client.odin`
- Recalculated packet budget: 28 entities + 8 projectiles = 1388 bytes (fits in 1400 MAX_PACKET_SIZE)

**Verification**: Build passes, Dominion test passes.

### 2. Dual UDP receive drops packets ✓
**Issue**: `main_client` called separate `network_client_receive` and `network_client_receive_gamestate` on the same socket, causing each to discard the other's packet type.

**Fix**:
- Unified receive into single dispatcher: `network_client_receive` now returns all three packet types (Snapshot, Welcome, GameState)
- Removed duplicate `network_client_receive_gamestate` function
- Updated `main_client` to use single receive loop that routes by `Packet_Type`

**Verification**: Build passes, no packet loss from multiple poll calls.

### 3. Lag-comp clamp unused ✓
**Issue**: Server was supposed to pass `clamped_tick` to `hitscan_check` but was using raw `client_tick`.

**Fix**:
- Updated `server_handle_spell_cast` line 811 to pass `clamped_tick` instead of `client_tick` to `hitscan_check()`
- The `clamped_tick` is computed from `max(server.tick_id - 60, client_tick)` to prevent excessive rewind
- Now lag compensation correctly uses the clamped value for rewinding entity positions

**Verification**: Code inspection and grep confirm correct usage.

## Playtest Sturdiness Fixes

### 4. Death / respawn (minimal) ✓
**Implementation**:
- Added `dead: bool` and `respawn_timer: f32` fields to `Character_State`
- New file: `src/death_respawn.odin`
  - `entity_tick_death_respawn()`: checks health <= 0, sets dead flag, starts 3-second timer
  - On timer expire: respawn at team spawn with full resources (health/mana/stamina)
- Integrated into `server_tick()` before simulation step
- Dead players excluded from Obelisk capture contribution in `obelisk_tick()`

**Verification**: Builds successfully.

### 5. Client disconnect timeout ✓
**Implementation**:
- Added `client_last_packet: [MAX_CLIENTS]time.Tick` to `Server`
- Update timestamp in `server_register_client()` on every packet from existing client
- In `server_tick()`: check for 5-second silence per client
  - If timeout detected: despawn entity, free client slot (swap-remove from arrays)
- Prevents `MAX_CLIENTS` exhaustion from silent/crashed clients

**Verification**: Builds successfully.

### 6. Disable artificial latency on graphical client ✓
**Implementation**:
- Removed default `network_client_sim_latency(50, 0.02)` call in `main_client.odin`
- Now only enabled if `ENABLE_SIM_LATENCY=1` environment variable is set
- Default playtest uses true network latency

**Verification**: Builds successfully.

### 7. Client tick catch-up ✓
**Implementation**:
- Client input loop now calculates `ticks_to_run` based on elapsed time since last tick
- Runs multiple sim/input steps per frame (capped at 5 to prevent spiral of death)
- Mouse deltas only reset after final tick in the batch
- Prevents client from permanently falling behind on long frames

**Verification**: Builds successfully.

## Test Results

```bash
$ ./test_dominion_match.sh
✓ Match started (left Waiting state)
✓ Obelisks captured (2 captures detected)
✓ Match ended without crash
=== Test PASSED ===
```

- Server builds: ✓
- Graphical client builds: ✓
- Dominion test passes: ✓
- Entity size constant verified: 42 bytes on both ser/deser paths

## Files Modified

### Core Network
- `src/network.odin`: ENTITY_SIZE=42, MAX_ENTITIES_IN_PACKET=28
- `src/network_client.odin`: Unified receive dispatcher, 42-byte entity bounds

### Client
- `src/main_client.odin`: Unified packet receive, env-gated sim latency, tick catch-up

### Server
- `src/server.odin`: Client timeout checking, death/respawn integration
- `src/entity.odin`: Added `dead` and `respawn_timer` fields
- `src/death_respawn.odin`: NEW - Death and respawn system
- `src/obelisks.odin`: Skip dead players in capture volume

## Nice-to-Have Items (Deferred)

The following "nice if cheap" items were **not** implemented to avoid blocking the PR:

- ❌ Frost Shard slow effect (speed multiplier during `slow_duration`)
  - Reason: Requires simulation changes and careful testing; not a playtest blocker
- ❌ Knockback impulse
  - Reason: `Character_State` doesn't have horizontal velocity fields; would need redesign
- ❌ Deduplicate `camera_forward` / SDTX constants
  - Reason: Low impact; current duplication is documented and manageable
- ❌ Full `cmd/server` + `cmd/client` layout
  - Reason: `build.sh` file filtering is working fine; not worth the refactor risk

These can be addressed in future polish passes without impacting public playtest stability.
