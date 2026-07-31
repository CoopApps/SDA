shader_type canvas_item;

// Recolours an INDEX image using a live palette. Each source texel encodes
// (r = colour index 0..15, g = palette number 0..3). The palette is a
// 16x4 lookup texture (x = colour index, y = palette number). Animating a
// palette effect = update `palette_tex`; this shader recolours every
// pixel on the GPU for free. Colour index 0 is transparent.

uniform sampler2D palette_tex : filter_nearest;
// Background planes paint colour-index 0 as the opaque backdrop; sprites
// must leave it transparent so they don't draw black boxes.
uniform bool opaque_backdrop = false;

void fragment() {
	// TEXTURE holds the index image; sample without filtering.
	vec4 src = texture(TEXTURE, UV);
	int color_idx = int(src.r * 255.0 + 0.5);
	int pal_num   = int(src.g * 255.0 + 0.5);
	if (color_idx == 0) {
		COLOR = opaque_backdrop
			? vec4(texture(palette_tex, vec2(0.5 / 16.0, 0.5 / 4.0)).rgb, 1.0)
			: vec4(0.0, 0.0, 0.0, 0.0);
	} else {
		float u = (float(color_idx) + 0.5) / 16.0;
		float vv = (float(pal_num) + 0.5) / 4.0;
		COLOR = vec4(texture(palette_tex, vec2(u, vv)).rgb, 1.0);
	}
}
