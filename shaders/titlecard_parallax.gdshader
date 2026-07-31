// Per-line horizontal parallax for the chapter title card (ports VDP hscroll
// table 0x17AE). Each scanline scrolls at its own rate (row_rate texture). The
// plane artwork is UNIQUE across the full 1024px (it repeats only at 1024, NOT
// every 256), so the scroll must wrap at the full plane width via fract() — a
// 256 wrap made the foreground trees jump/restart. Top band (rate 0) stays fixed.
shader_type canvas_item;

uniform sampler2D layer_tex : filter_nearest;   // 1024x224 RGBA plane layer
uniform sampler2D row_rate  : filter_nearest;   // 1x224, .r = rate/rate_scale
uniform float frame_count = 0.0;                 // advances 1 per game frame
uniform float rate_scale = 8.0;                  // max px/frame
uniform float screen_w = 256.0;
uniform float tex_w = 1024.0;

void fragment() {
	float rate = texture(row_rate, vec2(0.5, UV.y)).r * rate_scale;
	float src_x = UV.x * screen_w + rate * frame_count;
	COLOR = texture(layer_tex, vec2(fract(src_x / tex_w), UV.y));  // wrap @1024
}
