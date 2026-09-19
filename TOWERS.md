# Tower Shield-Node System

Replaces the occupancy-grid / voxel-column pylon authority with a spiral shield-node tower system for server-authoritative gameplay logic and scoring.

## Architecture (Fixed)

Each tower consists of:

1. **Thin Solid Core**: A vertical cylinder (radius = 0.6m) whose height is derived from `live_node_count * STACK_STEP`
   - Thin stack column / last stand, not a fat pillar
   - Collision surface for world_point_free
   - Not independently synced—height is computed from node count

2. **Shield Nodes (AoS)**: An array of nodes wrapping in a deterministic spiral around the core
   - Each node has: `Node_ID`, `hp`, `max_hp`, `alive`, `ore`, `team`
   - Fixed capacity per tower (24-32 nodes depending on tower type)
   - Nodes are the authoritative exo-shield (destructible surface)

3. **Spiral Positioning (Authoritative Sort)**: Node visual position is **derived** from sort rank
   - `sorted_indices[rank]` array maps rank → node array index
   - Uses golden angle (2.39996 radians) for spiral distribution
   - Radial position: `SPIRAL_BASE_RADIUS (2.8m) + z * SPIRAL_RADIUS_GROWTH`
   - Never stored as part of node identity

## Damage and Sorting (Fixed - Now Authoritative)

### Hit-Test Contract

- Mining/projectiles/beams target **Node_ID**, not spiral slot index
- Splash damage finds nodes within radius, damages by Node_ID
- When `node.hp <= 0`: mark `alive = false`, decrement `live_count`

### Re-Sort on Node Death (NOW WORKS)

After any node dies:
1. Filter to live nodes only with their array indices
2. Sort by: `hp DESC, then Node_ID ASC` (stable tie-break)
3. Store sorted array indices in `sorted_indices[rank] = array_index`
4. All node iteration uses `tower_node_at_rank(t, rank)` helper
5. Spiral position computed from rank via `tower_node_spiral_pos(rank, core_h)`

This ensures:
- High-HP nodes appear at bottom (rank 0, harder to reach)
- Low-HP nodes spiral upward (higher rank, easier targets)
- Node identity stable across resorts
- **Damage never "hops"—hits always address Node_ID**
- Collision, mining splash, and position all use sorted order

## Minion Rebuild

**1 minion = 1 node** (replaces splash rebuild-radius donation into occupancy).

When a minion reaches a damaged friendly tower:
1. Jump to top of core (at `core_height`)
2. Call `tower_build()`
3. Finds first dead node slot
4. Resurrect with fresh `Node_ID`, full HP
5. Re-sort live nodes
6. Minion removed from world

This preserves wave/economy intent from `MINIONS.md` while using nodes instead of voxel columns.

### Rebuild Trigger

- Friendly towers: `intact < PYLON_REBUILD_FRAC` (0.75)
- Centre (gold): `centre_open && intact < CENTRE_CLAIM_FRAC` (0.80)

## Capacity and MTU

| Tower Type | Max Nodes | Node HP | Intact Calculation |
|------------|-----------|---------|-------------------|
| Gold (centre) | 32 | 85 | `live_count / 32` |
| Near-lane | 28 | 35 | `live_count / 28` |
| Far-lane | 24 | 35 | `live_count / 24` |

### Wire Format

**Snapshot (30Hz dirty towers, max 2):**
- Tower ID: 1 byte
- Node HP array: 32 bytes (quantized 0-255, 0 = dead)
- **Total: 33 bytes per tower**

**GameState (10Hz all towers):**
- Intact: 1 byte
- Node HP array: 32 bytes
- **Total: 33 bytes × 7 towers = 231 bytes**

Old occupancy was 65 bytes per pylon (1 + 64). New node system is **33 bytes** (smaller despite more fidelity).

### MTU Safety

```
SNAPSHOT_WORST_BYTES = 
  SNAPSHOT_HEADER_BYTES (18) +
  MAX_SNAPSHOT_ENTITIES * SNAPSHOT_ENTITY_BYTES (15 * 43 = 645) +
  MAX_SNAPSHOT_MINIONS * SNAPSHOT_MINION_BYTES (14 * 11 = 154) +
  MAX_SNAPSHOT_PROJECTILES * SNAPSHOT_PROJECTILE_BYTES (12 * 16 = 192) +
  MAX_SNAPSHOT_STRIKES * SNAPSHOT_STRIKE_BYTES (4 * 8 = 32) +
  MAX_SNAPSHOT_BEAMS * SNAPSHOT_BEAM_BYTES (4 * 13 = 52) +
  MAX_SNAPSHOT_COMBAT_EVENTS * SNAPSHOT_EVENT_BYTES (8 * 6 = 48) +
  MAX_SNAPSHOT_OCC_PYLONS * SNAPSHOT_TOWER_NODE_BYTES (2 * 33 = 66) +
  MAX_SNAPSHOT_CHUNKS * SNAPSHOT_CHUNK_BYTES (8 * 13 = 104)
  = 1311 bytes < 1400 (MAX_PACKET_SIZE) ✓
```

## Collision (Fixed)

### Core Separation

- **CORE_RADIUS = 0.6m** (thin stack column, last stand when nodes gone)
- **SPIRAL_BASE_RADIUS = 2.8m** (nodes wrap around core at this radius)
- Beams/projectiles primarily hit **nodes** (the destructible exo-shield)
- Core is thin vertical cylinder, not a 2.8m pillar that swallows rays

### world_point_free Integration

Towers plug into `world_point_free` via `g_towers` global (same pattern as old `g_pylons`):

1. Cylinder-reject on tower bounding cylinder (spiral base radius + growth)
2. Check core: **thin** vertical cylinder (CORE_RADIUS) from 0 to `core_height`
3. Check nodes: sphere test against each live node's spiral position (by sorted rank)

### Raycast

`tower_raycast(world, ro, rd, max_t)` returns `(t, tower_id, node_id, hit)`:
- Clip ray to bounding cylinder
- March in steps, checking **thin core** (0.6m) + nodes
- Returns `node_id = 0` for core hit, `node_id > 0` for node hit

## Server Changes

### Removed
- `pylon_world_init/reset/tick`
- `pylon_blocks_point`
- `pylon_raycast`
- `pylon_mine/pylon_build`
- `ore_grid.odin` (no longer authoritative)
- Occupancy height blobs from network protocol

### Added
- `tower_nodes.odin`: complete tower system
- `tower_world_init/reset/tick`
- `tower_blocks_point`
- `tower_raycast`
- `tower_mine/tower_build`
- Node HP array in protocol (quantized 0-255)

### Updated Files
- `world_map.odin`: `world_point_free` → `tower_blocks_point`
- `mining.odin`: beams/blasts → tower raycast + mine
- `minions.odin`: rebuild logic → tower build (1 minion = 1 node)
- `match.odin`: centre win condition → `tower.live_count`
- `server.odin`: init/tick/reset → towers
- `network.odin`: protocol v14, tower node packets

## Client Rendering (Minimal)

Server changes only. Client must draw:
- Core: vertical cylinder at tower base, height = `core_height`
- Nodes: capsules/boxes at derived spiral positions
- Node HP: color or scale by `node_hp[i] / 255.0`

**Out of scope for this PR:**
- SDF "paint" over spiral
- Smooth node position morphing between slots
- Fancy VFX

## Remaining Work (Future PRs)

1. **Ore carry-to-base redesign**: instant banking may need carrier mechanic
2. **Bot AI**: path around node towers, target low-HP nodes
3. **Wave leash**: ensure minions path correctly with new collision
4. **HUD**: tower health bars, node count display
5. **Full art pass**: node models, SDF skin, destruction VFX
6. **Client prediction**: local node HP interpolation

## Behavior Mapping (Old → New)

| Old Occupancy | New Nodes |
|---------------|-----------|
| 8×8×20 voxel grid, 1280 cells | 24-32 nodes per tower |
| HP per cell (u8, 0-8) | HP per node (f32, quantized to u8 on wire) |
| Column heights (64 bytes) | Node HP array (32 bytes) |
| Gravity: compact column on damage | Sort: re-order by HP after death |
| Splash hits cells in radius | Splash hits nodes in radius (by Node_ID) |
| Minion hop: spread donation across columns | Minion hop: add 1 node at top |
| Occupancy → pylon_intact | live_count / max_count → tower.intact |
| Cell position = (x, y, stack_height) | Node position = spiral(sort_rank) |

## Testing Notes

Build with: `./build.sh server` (or PowerShell: `.\build.ps1 -Target server`)

**Expected behavior:**
1. Towers stand at 7 positions (centre + 6 lane)
2. Mining damages nodes, kills reduce live_count
3. Dead nodes re-sort: low-HP nodes rise in spiral
4. Core height shrinks as nodes die
5. Minions donate: add 1 node, increase live_count
6. Centre win: first team to rebuild ≥80% wins round

**Protocol compatibility:**
- PROTOCOL_VERSION bumped to 14
- Old clients (v13) cannot connect
- Snapshot + GameState packets updated

## Performance Notes

- No per-tick marching or SDF evaluation (server-side)
- Node collision: simple sphere tests
- Core collision: single cylinder test
- Re-sort only on node death (not per-tick)
- Wire format smaller than old occupancy (33 vs 65 bytes)

Collision cost: 7 towers × (1 cylinder + max 32 sphere tests) ≈ 231 checks worst case. Cylinder reject brings average case down to ~10-20 checks per `world_point_free` call that touches a tower.

## Blockers Fixed (PR Quality Review)

### ✅ Blocker 1 - Resort now authoritative
- Added `sorted_indices[MAX_NODES_PER_TOWER]` to Tower struct
- `tower_resort_nodes` stores sorted array indices, not just temp sort
- All node iteration uses `tower_node_at_rank(t, rank)` helper
- Mining splash, collision, and position all use sorted order
- Spiral slot is pure function of current HP-sort rank

### ✅ Blocker 2 - Core thin, not fat
- Separated `CORE_RADIUS = 0.6m` (thin core) from `SPIRAL_BASE_RADIUS = 2.8m` (node spiral)
- All collision/raycast updated to use CORE_RADIUS for core checks
- Beams/projectiles now primarily hit nodes (destructible exo-shield)
- Core is thin stack column / last stand, not 2.8m pillar that swallows rays

### ✅ Blocker 3 - Client updated and playable
- Replaced `Pylon_World` with `Tower_World` in client_prediction
- Added `tower_unpack_nodes` for wire → client state
- `client_world_apply_gamestate_towers` / `apply_snapshot_towers` unpack node HP
- Updated client_renderer to use tower state (stub SDF march)
- Fixed HUD to show `tower.intact` percentages
- Removed pylon texture/atlas GPU state (no SDF upload this PR)
- **Client can connect, see tower state, collision works**

### ✅ Blocker 4 - Dual authority removed
- `g_pylons` no longer used anywhere (`g_towers` is sole authority)
- `ore_grid.odin` no longer in gameplay collision/mining paths
- Only `tower_blocks_point` used by `world_point_free`
- Keep `pylons.odin` for shared helpers only (ore_color, team_ore, constants)
