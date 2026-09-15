// Phase 5: Chunk Streaming Scaffold
// Load/unload world chunks (NVMe-backed, MMO-ready)
package main

import "core:fmt"
import "core:os"
import "core:path/filepath"

// Chunk data (minimal stub for now)
Chunk_Data :: struct {
	chunk_id:    Chunk_ID,
	loaded:      bool,
	// Future: terrain heightmap, static geometry, spawners, etc.
}

// Chunk streaming system
Chunk_Streaming :: struct {
	chunks:      map[Chunk_ID]Chunk_Data,
	chunk_dir:   string,  // Path to chunk storage (e.g. /data/chunks/)
}

// Initialize chunk streaming
chunk_streaming_init :: proc(chunk_dir: string) -> Chunk_Streaming {
	cs := Chunk_Streaming{
		chunks = make(map[Chunk_ID]Chunk_Data),
		chunk_dir = chunk_dir,
	}
	
	// Ensure chunk directory exists
	os.make_directory(chunk_dir)
	
	fmt.printf("[ChunkStreaming] Initialized with directory: %s\n", chunk_dir)
	return cs
}

// Cleanup
chunk_streaming_shutdown :: proc(cs: ^Chunk_Streaming) {
	delete(cs.chunks)
	fmt.println("[ChunkStreaming] Shutdown")
}

// Get chunk file path
chunk_get_path :: proc(cs: ^Chunk_Streaming, chunk_id: Chunk_ID) -> string {
	// Format: chunks/x_y_z.chunk
	filename := fmt.tprintf("%d_%d_%d.chunk", chunk_id.x, chunk_id.y, chunk_id.z)
	path, _ := filepath.join({cs.chunk_dir, filename})
	return path
}

// Load chunk from disk (stub: just marks as loaded)
chunk_load :: proc(cs: ^Chunk_Streaming, chunk_id: Chunk_ID) -> bool {
	// Check if already loaded
	if chunk_id in cs.chunks && cs.chunks[chunk_id].loaded {
		return true
	}
	
	chunk_path := chunk_get_path(cs, chunk_id)
	
	// For now, just mark as loaded (no actual disk I/O yet)
	// Future: Read heightmap, spawners, static geometry from NVMe
	chunk_data := Chunk_Data{
		chunk_id = chunk_id,
		loaded = true,
	}
	cs.chunks[chunk_id] = chunk_data
	
	fmt.printf("[ChunkStreaming] Loaded chunk (%d, %d, %d) from %s\n", 
		chunk_id.x, chunk_id.y, chunk_id.z, chunk_path)
	
	return true
}

// Unload chunk (free memory)
chunk_unload :: proc(cs: ^Chunk_Streaming, chunk_id: Chunk_ID) {
	if chunk_id not_in cs.chunks {
		return
	}
	
	delete_key(&cs.chunks, chunk_id)
	fmt.printf("[ChunkStreaming] Unloaded chunk (%d, %d, %d)\n", 
		chunk_id.x, chunk_id.y, chunk_id.z)
}

// Save chunk to disk (stub)
chunk_save :: proc(cs: ^Chunk_Streaming, chunk_id: Chunk_ID) -> bool {
	if chunk_id not_in cs.chunks {
		return false
	}
	
	chunk_path := chunk_get_path(cs, chunk_id)
	
	// Future: Write heightmap, spawners, static geometry to NVMe
	// For now, just log
	fmt.printf("[ChunkStreaming] Saved chunk (%d, %d, %d) to %s\n", 
		chunk_id.x, chunk_id.y, chunk_id.z, chunk_path)
	
	return true
}

// Check if chunk is loaded
chunk_is_loaded :: proc(cs: ^Chunk_Streaming, chunk_id: Chunk_ID) -> bool {
	if chunk_id not_in cs.chunks {
		return false
	}
	return cs.chunks[chunk_id].loaded
}

// Get chunks in radius (for streaming)
chunk_get_in_radius :: proc(
	cs: ^Chunk_Streaming,
	center_chunk: Chunk_ID,
	radius_chunks: i64,
	allocator := context.allocator,
) -> []Chunk_ID {
	chunks := make([dynamic]Chunk_ID, allocator)
	
	for x in center_chunk.x - radius_chunks ..= center_chunk.x + radius_chunks {
		for y in center_chunk.y - radius_chunks ..= center_chunk.y + radius_chunks {
			for z in center_chunk.z - radius_chunks ..= center_chunk.z + radius_chunks {
				append(&chunks, Chunk_ID{x, y, z})
			}
		}
	}
	
	return chunks[:]
}
