@header package main
@header import sg "sokol:gfx"

@ctype vec3 vec3
@ctype vec4 vec4

@vs vs
layout(binding=0) uniform vs_params {
    vec3 cam_pos;
    float half_w;
    vec3 cam_right;
    float half_h;
    vec3 cam_up;
    float _pad0;
    vec3 cam_forward;
    float _pad1;
};

in vec2 position;
out vec3 ray_origin;
out vec3 ray_dir;

void main() {
    gl_Position = vec4(position, 0.0, 1.0);
    ray_origin = cam_pos;
    ray_dir = cam_forward + cam_right * (position.x * half_w) + cam_up * (position.y * half_h);
}
@end

@fs fs
layout(binding=1) uniform fs_params {
    vec3 room_min;
    float world_t;
    vec3 room_max;
    float flash;
    vec3 lamp_pos;
    float kick;
    vec3 gun_grip;
    float gun_on;
    vec3 gun_muzzle;
    float _pad_g;
    vec3 gun_right;
    float _pad_r;
    vec3 gun_up;
    float _pad_u;
    vec4 impact0;
    vec4 impact1;
    vec4 impact2;
    vec4 impact3;
    vec4 impact4;
    vec4 impact5;
    vec4 impact6;
    vec4 impact7;
    vec4 projectiles[16];
};

in vec3 ray_origin;
in vec3 ray_dir;
out vec4 frag_color;

const uint MAT_WALL = 1u;
const uint MAT_FLOOR = 2u;
const uint MAT_CEIL = 3u;
const uint MAT_GUN_METAL = 4u;
const uint MAT_GUN_GRIP = 5u;
const uint MAT_FLASH = 6u;
const uint MAT_PROJECTILE = 7u;

bool intersect_aabb(vec3 ro, vec3 inv, vec3 bmin, vec3 bmax, out float t0, out float t1) {
    vec3 tbot = (bmin - ro) * inv;
    vec3 ttop = (bmax - ro) * inv;
    vec3 ts = min(ttop, tbot);
    vec3 tb = max(ttop, tbot);
    t0 = max(max(ts.x, ts.y), ts.z);
    t1 = min(min(tb.x, tb.y), tb.z);
    return t1 >= max(t0, 0.0);
}

float lamp(vec3 p, vec3 n, vec3 lp, float intensity, float r2, vec3 tint) {
    vec3 l = lp - p;
    float d2 = dot(l, l);
    if (d2 > r2 * 6.0) {
        return 0.0;
    }
    float att = intensity / (1.0 + d2 * 2.8);
    float nd = max(dot(n, normalize(l)), 0.0);
    return att * (0.25 + 0.75 * nd);
}

float sd_box(vec3 p, vec3 b) {
    vec3 q = abs(p) - b;
    return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0);
}

float sd_capsule(vec3 p, vec3 a, vec3 b, float r) {
    vec3 pa = p - a;
    vec3 ba = b - a;
    float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    return length(pa - ba * h) - r;
}

vec3 gun_local(vec3 p) {
    vec3 z = normalize(gun_muzzle - gun_grip);
    vec3 x = normalize(gun_right);
    vec3 y = normalize(gun_up);
    vec3 d = p - gun_grip;
    return vec3(dot(d, x), dot(d, y), dot(d, z));
}

float gun_metal_sd(vec3 l) {
    float rec = sd_box(l - vec3(0.0, 0.012, 0.10), vec3(0.018, 0.020, 0.10));
    float slide = sd_box(l - vec3(0.0, 0.028, 0.12), vec3(0.016, 0.009, 0.11));
    float bar = sd_capsule(l, vec3(0.0, 0.016, 0.18), vec3(0.0, 0.016, 0.36), 0.007);
    float guard = sd_box(l - vec3(0.0, -0.010, 0.078), vec3(0.007, 0.016, 0.016));
    return min(min(rec, slide), min(bar, guard));
}

float gun_grip_sd(vec3 l) {
    return sd_box(l - vec3(0.0, -0.042, 0.048), vec3(0.012, 0.044, 0.022));
}

float gun_map(vec3 p) {
    vec3 l = gun_local(p);
    return min(gun_metal_sd(l), gun_grip_sd(l));
}

bool gun_trace(vec3 ro, vec3 rd, float tmax, out float t, out vec3 n, out uint mat) {
    t = 0.0;
    n = vec3(0.0, 0.0, 1.0);
    mat = 0u;
    vec3 pc = 0.5 * (gun_grip + gun_muzzle);
    float pr = 0.5 * length(gun_muzzle - gun_grip) + 0.16;
    vec3 oc = ro - pc;
    float b = dot(oc, rd);
    float h = b * b - dot(oc, oc) + pr * pr;
    if (h < 0.0) {
        return false;
    }
    float ts = -b - sqrt(h);
    t = ts > 0.02 ? ts : 0.02;
    if (t >= tmax) {
        return false;
    }
    for (int i = 0; i < 28; i++) {
        vec3 p = ro + rd * t;
        float d = gun_map(p);
        if (d < 0.0008) {
            float e = 0.0014;
            n = normalize(vec3(
                gun_map(p + vec3(e, 0, 0)) - gun_map(p - vec3(e, 0, 0)),
                gun_map(p + vec3(0, e, 0)) - gun_map(p - vec3(0, e, 0)),
                gun_map(p + vec3(0, 0, e)) - gun_map(p - vec3(0, 0, e))
            ));
            vec3 l = gun_local(p);
            mat = gun_grip_sd(l) < gun_metal_sd(l) + 0.0005 ? MAT_GUN_GRIP : MAT_GUN_METAL;
            return true;
        }
        t += max(d, 0.0008);
        if (t >= tmax || t > 2.4) {
            return false;
        }
    }
    return false;
}

bool flash_trace(vec3 ro, vec3 rd, float tmax, out float t, out vec3 n) {
    t = 0.0;
    n = vec3(0.0, 0.0, 1.0);
    if (flash < 0.12) {
        return false;
    }
    float rad = 0.018 + 0.034 * flash;
    vec3 oc = ro - gun_muzzle;
    float b = dot(oc, rd);
    float h = b * b - dot(oc, oc) + rad * rad;
    if (h < 0.0) {
        return false;
    }
    t = -b - sqrt(h);
    if (t < 0.02 || t >= tmax) {
        return false;
    }
    n = normalize((ro + rd * t) - gun_muzzle);
    return true;
}

bool projectile_trace(vec3 ro, vec3 rd, float tmax, out float t, out vec3 n, out float spell_type) {
    t = tmax;
    n = vec3(0.0, 0.0, 1.0);
    spell_type = 0.0;
    bool hit = false;
    
    for (int i = 0; i < 16; i++) {
        vec4 proj = projectiles[i];
        if (proj.w <= 0.0) {
            continue;
        }
        
        vec3 center = proj.xyz;
        float radius = abs(proj.w);
        spell_type = sign(proj.w);
        
        vec3 oc = ro - center;
        float b = dot(oc, rd);
        float c = dot(oc, oc) - radius * radius;
        float disc = b * b - c;
        
        if (disc < 0.0) {
            continue;
        }
        
        float t_hit = -b - sqrt(disc);
        if (t_hit >= 0.02 && t_hit < t) {
            t = t_hit;
            n = normalize((ro + rd * t) - center);
            hit = true;
        }
    }
    
    return hit;
}

bool room_hit(vec3 ro, vec3 rd, vec3 inv, out float t, out vec3 n, out uint mat) {
    t = 0.0;
    n = vec3(0.0, 0.0, 1.0);
    mat = 0u;
    float t0, t1;
    if (!intersect_aabb(ro, inv, room_min, room_max, t0, t1)) {
        return false;
    }
    t = t0 > 0.02 ? t0 : t1;
    if (t < 0.0) {
        return false;
    }
    vec3 p = ro + rd * t;
    vec3 c = 0.5 * (room_min + room_max);
    vec3 ext = max(room_max - room_min, vec3(1e-4));
    vec3 d = (p - c) / (0.5 * ext);
    vec3 ad = abs(d);
    n = vec3(0.0);
    if (ad.x > ad.y && ad.x > ad.z) {
        n.x = -sign(d.x);
        mat = MAT_WALL;
    } else if (ad.y > ad.z) {
        n.y = -sign(d.y);
        mat = MAT_WALL;
    } else {
        n.z = -sign(d.z);
        mat = n.z > 0.0 ? MAT_FLOOR : MAT_CEIL;
    }
    return true;
}

float scorch(vec3 hp, vec4 im) {
    if (im.w <= 0.001) {
        return 0.0;
    }
    float d = length(hp - im.xyz);
    return (1.0 - smoothstep(0.0, 0.11, d)) * im.w;
}

void main() {
    vec3 ro = ray_origin;
    vec3 rd = normalize(ray_dir);
    vec3 inv = 1.0 / rd;

    float hit_t = -1.0;
    vec3 hit_n = vec3(0.0, 0.0, 1.0);
    uint hit_mat = 0u;
    bool is_gun = false;
    bool is_flash = false;
    bool is_projectile = false;
    float proj_spell_type = 0.0;

    float rt;
    vec3 rn;
    uint rm;
    if (room_hit(ro, rd, inv, rt, rn, rm)) {
        hit_t = rt;
        hit_n = rn;
        hit_mat = rm;
    }

    float best = hit_t > 0.0 ? hit_t : 2.4;
    
    // Check projectiles
    float pt;
    vec3 pn;
    float ptype;
    if (projectile_trace(ro, rd, best, pt, pn, ptype)) {
        hit_t = pt;
        hit_n = pn;
        hit_mat = MAT_PROJECTILE;
        proj_spell_type = ptype;
        is_projectile = true;
        best = pt;
    }
    
    if (gun_on > 0.5) {
        float gt;
        vec3 gn;
        uint gm;
        if (gun_trace(ro, rd, best, gt, gn, gm)) {
            hit_t = gt;
            hit_n = gn;
            hit_mat = gm;
            is_gun = true;
            is_projectile = false;
            best = gt;
        }
        float ft;
        vec3 fn;
        if (flash_trace(ro, rd, best, ft, fn)) {
            hit_t = ft;
            hit_n = fn;
            hit_mat = MAT_FLASH;
            is_flash = true;
            is_gun = false;
            is_projectile = false;
        }
    }

    vec3 bg = vec3(0.028, 0.030, 0.038);
    if (hit_t < 0.0) {
        frag_color = vec4(bg, 1.0);
        return;
    }

    vec3 hp = ro + rd * hit_t;
    if (dot(hit_n, rd) > 0.0) {
        hit_n = -hit_n;
    }

    vec3 albedo = vec3(0.42, 0.40, 0.36);
    if (hit_mat == MAT_FLOOR) {
        float cx = floor(hp.x * 2.0);
        float cy = floor(hp.y * 2.0);
        float chk = mod(cx + cy, 2.0);
        albedo = mix(vec3(0.38, 0.36, 0.32), vec3(0.22, 0.21, 0.19), chk);
    } else if (hit_mat == MAT_CEIL) {
        albedo = vec3(0.55, 0.54, 0.50);
    } else if (hit_mat == MAT_WALL) {
        albedo = vec3(0.62, 0.58, 0.50);
        if (abs(hit_n.x) > 0.8 && hit_n.x < 0.0) {
            albedo = vec3(0.52, 0.42, 0.34);
        }
    } else if (hit_mat == MAT_GUN_METAL) {
        albedo = vec3(0.16, 0.17, 0.18);
    } else if (hit_mat == MAT_GUN_GRIP) {
        albedo = vec3(0.22, 0.12, 0.08);
    } else if (hit_mat == MAT_FLASH) {
        albedo = vec3(1.0, 0.82, 0.42);
    } else if (hit_mat == MAT_PROJECTILE) {
        // Color by spell type: 1=Missile(purple), 2=Orb(blue), 3=Blink(white), 4=Frost(cyan)
        if (proj_spell_type == 1.0) {
            albedo = vec3(0.82, 0.42, 0.92);  // Arcane purple
        } else if (proj_spell_type == 2.0) {
            albedo = vec3(0.52, 0.62, 0.92);  // Arcane blue
        } else if (proj_spell_type == 3.0) {
            albedo = vec3(0.92, 0.92, 0.98);  // Blink white
        } else if (proj_spell_type == 4.0) {
            albedo = vec3(0.42, 0.82, 0.92);  // Frost cyan
        } else {
            albedo = vec3(0.92, 0.82, 0.42);  // Default yellow
        }
    }

    float burn = 0.0;
    burn = max(burn, scorch(hp, impact0));
    burn = max(burn, scorch(hp, impact1));
    burn = max(burn, scorch(hp, impact2));
    burn = max(burn, scorch(hp, impact3));
    burn = max(burn, scorch(hp, impact4));
    burn = max(burn, scorch(hp, impact5));
    burn = max(burn, scorch(hp, impact6));
    burn = max(burn, scorch(hp, impact7));
    if (!is_gun && !is_flash && !is_projectile && burn > 0.0) {
        albedo *= 1.0 - burn * 0.82;
        albedo += vec3(0.12, 0.04, 0.01) * burn;
    }

    vec3 color = albedo * 0.04;
    if (is_flash) {
        color = albedo * (0.85 + 1.4 * flash);
    } else if (is_projectile) {
        // Projectiles glow brightly
        float ndv = max(dot(hit_n, -rd), 0.0);
        float fresnel = pow(1.0 - ndv, 2.0);
        color = albedo * (0.85 + 0.65 * fresnel);
    } else if (is_gun) {
        float ndv = max(dot(hit_n, -rd), 0.0);
        float wrap = 0.22 + 0.78 * ndv;
        float spec = pow(ndv, hit_mat == MAT_GUN_METAL ? 32.0 : 8.0);
        spec *= hit_mat == MAT_GUN_METAL ? 0.38 : 0.06;
        color = albedo * wrap * vec3(0.95, 0.88, 0.78) + vec3(1.0, 0.96, 0.88) * spec;
        color += albedo * lamp(hp, hit_n, lamp_pos, 1.4, 8.0, vec3(1.0, 0.92, 0.78)) * 0.35;
        if (flash > 0.25) {
            color += vec3(1.0, 0.78, 0.38) * flash * (hit_mat == MAT_GUN_METAL ? 0.55 : 0.18);
        }
    } else {
        color += albedo * lamp(hp, hit_n, lamp_pos, 3.2, 48.0, vec3(1.0, 0.92, 0.78)) * vec3(1.0, 0.93, 0.82);
        color += albedo * vec3(0.08, 0.09, 0.11);
        if (flash > 0.2) {
            color += albedo * lamp(hp, hit_n, gun_muzzle, 2.2 * flash, 4.0, vec3(1.0, 0.72, 0.32)) * vec3(1.0, 0.78, 0.40);
        }
    }

    float fog = (is_gun || is_flash || is_projectile) ? 0.0 : clamp(hit_t / 28.0, 0.0, 1.0);
    fog *= fog;
    color = mix(color, bg, fog);
    color = clamp(color, vec3(0.0), vec3(1.0));
    frag_color = vec4(color, 1.0);
}
@end

@program scene vs fs
