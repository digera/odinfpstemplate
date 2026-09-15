# Nexus Arena - Headless Deterministic Kernel (Phase 1)

Fast-paced FPS spell-slinger arena game built on a deterministic server architecture. Phase 1 establishes the headless server foundation with 60Hz tick, data-oriented entity system, and network protocol scaffold.

## Quick Start

### Build and Run Server
```bash
export ODIN_ROOT=/path/to/odin-compiler
./build.sh
./bin/nexus_server
```

### What You'll See
```
=== Nexus Arena Headless Server ===
Initializing server on port 27015 with 16 bots...
Server initialized: 16 bots spawned, 16 entities active

=== Starting server tick loop (60Hz) ===

[Server Stats] Uptime: 5.0s | Ticks: 301 | Entities: 16 | Avg tick: 0.009ms | Max tick: 0.013ms
  Bot positions: B0=(2.30,1.37,0.00) B1=(3.16,11.18,0.00) B2=(15.78,0.94,0.00)
```

## Phase 1 Deliverables

✅ **Fixed 60Hz Deterministic Tick** - Stable timing, no drift  
✅ **Shared Simulation Kernel** - `simulate_character_step()` for client/server  
✅ **Network Protocol Scaffold** - Bit-packed UDP (ready for Phase 2)  
✅ **16-Bot Headless Server** - Jumping/strafing bots, 0.009ms avg tick time  
✅ **Data-Oriented Entity System** - #soa arrays, numeric IDs, MMO-ready  

## Performance

- **Tick Rate**: 60 Hz (stable)
- **Avg Tick Time**: 0.009 ms (22x better than 0.2ms target)
- **Max Tick Time**: 0.013 ms (no spikes)
- **Headroom**: 99.95% of frame budget unused

## Architecture

### Core Simulation (`src/simulation.odin`)
Deterministic character physics shared between client and server:
- Cylinder collision vs AABB room
- Gravity, jumping, ground detection
- WASD movement with yaw-relative strafe

### Entity World (`src/entity.odin`)
Data-oriented storage with #soa (struct-of-arrays):
```odin
Entity_World :: struct {
    characters: #soa[MAX_ENTITIES]Character_State,
    inputs:     [MAX_ENTITIES]Input_State,
}
```

Cache-friendly iteration, SIMD-ready, MMO-scalable.

### Network Protocol (`src/network.odin`)
Minimal UDP packet formats:
- **Client → Server**: Input packet (15 bytes) at 60 Hz
- **Server → Client**: Snapshot packet (7 + 33n bytes) at 20-30 Hz

### Headless Server (`src/server.odin`)
Fixed-timestep loop with bot AI:
- Random movement + jumping
- Smooth yaw interpolation
- Stats every 5 seconds

## Game Vision (Future Phases)

**Nexus Arena** will be a competitive FPS spell-slinger with:
- Bunny-hop / air-strafe / slide movement
- Pure skillshot combat (4 spell archetypes)
- Nexus Dominion mode (capture Obelisks)
- MMO-ready architecture (large worlds, spatial partitioning)

**Phase 1** establishes the deterministic kernel. Future phases add:
- Client prediction & rollback
- Spell system (Health/Mana/Stamina)
- Rendering integration
- Game mode logic
- Spatial grid for large worlds

## Project Structure

```
src/
├── simulation.odin      # ⭐ THE KERNEL - shared deterministic physics
├── entity.odin          # Data-oriented entity storage (#soa)
├── network.odin         # UDP protocol scaffold
├── server.odin          # Headless server + bot AI
├── main_server.odin     # Server entry point
│
├── [Original Template Files]
├── main.odin            # Client entry (Windows only for now)
├── render.odin          # Sokol graphics (template)
├── player.odin          # Player state (template)
└── ...

build.sh                 # Linux build script
PHASE1_REPORT.md         # Detailed implementation report
```

## Building from Source

### Prerequisites
- **Odin Compiler**: dev-2026-09 or newer
- **LLVM 18**: For building Odin (if not using pre-built)
- **Linux/Unix**: Phase 1 server is Linux-focused

### Build Odin (if needed)
```bash
sudo apt-get install -y llvm-18 llvm-18-dev clang-18 libstdc++-14-dev
git clone --depth=1 https://github.com/odin-lang/Odin.git
cd Odin
LLVM_CONFIG=llvm-config-18 CXX=clang++-18 ./build_odin.sh
export ODIN_ROOT=$(pwd)
```

### Build Server
```bash
cd /path/to/nexus-arena
./build.sh
```

### Build Options
Edit `build.sh` to set:
- `BUILD_FLAGS`: Add `-o:speed` for release build

Edit `src/server.odin` to configure:
- `PORT`: Server UDP port (default 27015)
- `BOT_COUNT`: Number of bots (default 16, max 64)

## Testing

Run server for 30 seconds and verify metrics:
```bash
timeout 30 ./bin/nexus_server | tee test.log
grep "Server Stats" test.log
```

Expected: Stable 60Hz, ~0.009ms tick time, changing bot positions.

## Technical Details

### Determinism
- Fixed timestep: 1/60 second
- Explicit f32 math (no float64)
- Reproducible collision resolution
- No frame-to-frame drift observed

### Data-Oriented Design
Uses Odin's `#soa` for optimal cache usage:
```odin
// Memory layout:
[pos0, pos1, ..., pos63]  // All positions contiguous
[vel0, vel1, ..., vel63]  // All velocities contiguous
```

Benefits:
- Cache-friendly iteration (simulate_world_step)
- SIMD-ready (future optimization)
- Matches MMO server patterns

### Network (Phase 2 Ready)
Protocol defined but not yet integrated:
- UDP socket bound on port 27015
- Serialization/deserialization implemented
- Non-blocking I/O ready

Phase 2 will add:
- Client input processing
- Snapshot broadcasting (20-30 Hz)
- Delta compression

## Known Limitations

1. **Client not connected** - Server runs standalone, no client integration yet
2. **Room-only collision** - Hardcoded 16×16×4m room, no world geometry
3. **Network stub** - Protocol defined but packets not processed
4. **Bot AI is random** - No pathfinding or tactics
5. **Single-threaded** - All entities on main thread

These are **intentional** for Phase 1 scope. Extensions are well-documented.

## Contributing

Phase 1 is feature-complete. Phase 2+ will add:
- Client prediction (copy simulation kernel to client)
- Spell system (resource pools, casting, projectiles)
- Rendering (integrate template renderer with entity world)
- Game mode (Obelisk capture logic)
- Spatial grid (MMO-scale worlds)

See `PHASE1_REPORT.md` for detailed implementation notes and extension points.

## License

Based on the Odin FPS Template. Code is provided for review and extension.

## Credits

- **Odin FPS Template**: Starting point (player movement, Sokol renderer)
- **Phase 1 Implementation**: Headless deterministic kernel, entity system, network scaffold

---

**Status**: Phase 1 Complete ✅  
**Next**: Client integration + prediction (Phase 2)
