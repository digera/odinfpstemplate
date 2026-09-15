package main

import "core:math"

// Minimal camera functions needed by server simulation

camera_forward :: proc(yaw, pitch: f32) -> vec3 {
	cp := math.cos(pitch)
	return {math.cos(yaw) * cp, math.sin(yaw) * cp, math.sin(pitch)}
}

camera_right :: proc(yaw: f32) -> vec3 {
	return {math.sin(yaw), -math.cos(yaw), 0}
}
