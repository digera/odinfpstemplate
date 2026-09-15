package main

import "base:runtime"

// Conditional compilation for headless server vs client

when ODIN_OS != .Windows {
	// On Linux, check if HEADLESS_SERVER is defined
	when #defined(HEADLESS_SERVER) {
		// Headless server build
		main :: proc() {
			main_server()
		}
	} else {
		// Client build (requires Sokol + graphics)
		main :: proc() {
			main_client()
		}
	}
} else {
	// Windows: Original template client or new client
	import sapp "sokol:app"
	import slog "sokol:log"

	when #defined(USE_NEW_CLIENT) {
		// New networked client
		main :: proc() {
			main_client()
		}
	} else {
		// Original template (standalone, no networking)
		init :: proc "c" () {
			context = runtime.default_context()
			renderer_init()
		}

		frame :: proc "c" () {
			context = runtime.default_context()
			renderer_frame()
		}

		cleanup :: proc "c" () {
			context = runtime.default_context()
			renderer_shutdown()
		}

		main :: proc() {
			sapp.run({
				init_cb       = init,
				frame_cb      = frame,
				cleanup_cb    = cleanup,
				event_cb      = input_event,
				width         = WINDOW_W,
				height        = WINDOW_H,
				sample_count  = 1,
				high_dpi      = false,
				window_title  = "Odin FPS",
				icon          = {sokol_default = true},
				logger        = {func = slog.func},
				swap_interval = 1,
			})
		}
	}
}
