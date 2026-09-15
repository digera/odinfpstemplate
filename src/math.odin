package main

import "core:math"

vec2 :: distinct [2]f32
vec3 :: distinct [3]f32
vec4 :: distinct [4]f32
mat4 :: distinct [4][4]f32

lerpf :: proc(a, b, t: f32) -> f32 {
	return a + (b - a) * t
}

clampf :: proc(v, lo, hi: f32) -> f32 {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

saturate :: proc(v: f32) -> f32 {
	return clampf(v, 0, 1)
}

dot_vec3 :: proc(a, b: vec3) -> f32 {
	return a.x * b.x + a.y * b.y + a.z * b.z
}

len_vec3 :: proc(v: vec3) -> f32 {
	return math.sqrt(dot_vec3(v, v))
}

// Alias for consistency
length_vec3 :: proc(v: vec3) -> f32 {
	return len_vec3(v)
}

len2_vec3 :: proc(v: vec3) -> f32 {
	return dot_vec3(v, v)
}

// Linear interpolation for vec3
lerpv3 :: proc(a, b: vec3, t: f32) -> vec3 {
	return vec3{
		lerpf(a.x, b.x, t),
		lerpf(a.y, b.y, t),
		lerpf(a.z, b.z, t),
	}
}

norm_vec3 :: proc(v: vec3) -> vec3 {
	l := len_vec3(v)
	if l == 0 {
		return {}
	}
	return {v.x / l, v.y / l, v.z / l}
}

cross_vec3 :: proc(a, b: vec3) -> vec3 {
	return {
		(a.y * b.z) - (a.z * b.y),
		(a.z * b.x) - (a.x * b.z),
		(a.x * b.y) - (a.y * b.x),
	}
}

hash_u32 :: proc(n: u32) -> u32 {
	x := n
	x = (x ~ (x >> 16)) * 0x7FEB_352D
	x = (x ~ (x >> 15)) * 0x846C_A68B
	return x ~ (x >> 16)
}
