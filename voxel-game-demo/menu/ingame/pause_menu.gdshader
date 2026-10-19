shader_type canvas_item;

// Hint forces screen texture lookup capability
uniform sampler2D SCREEN_TEXTURE : hint_screen_texture, filter_linear_mipmap;
uniform float blur_intensity : hint_range(0.0, 5.0) = 2.0;

void fragment() {
    // Relying on manual multi-tap offsets is safer for Compatibility rendering
    vec2 tex_size = vec2(textureSize(SCREEN_TEXTURE, 0));
    vec2 uv = SCREEN_UV;
    
    vec4 color = texture(SCREEN_TEXTURE, uv);
    color += texture(SCREEN_TEXTURE, uv + vec2(blur_intensity) / tex_size);
    color += texture(SCREEN_TEXTURE, uv - vec2(blur_intensity) / tex_size);
    color += texture(SCREEN_TEXTURE, uv + vec2(blur_intensity, -blur_intensity) / tex_size);
    color += texture(SCREEN_TEXTURE, uv + vec2(-blur_intensity, blur_intensity) / tex_size);
    
    COLOR = color / 5.0;
}
