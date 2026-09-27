shader_type canvas_item;

uniform float scanline_speed = 5.0;
uniform float scanline_intensity : hint_range(0.0, 2.0) = 0.5;
uniform float scanline_frequency = 30.0;
uniform float scanline_thickness : hint_range(1.0, 100.0) = 20.0;
uniform float scanline_angle_degrees : hint_range(0.0, 360.0) = 0.0;
uniform float rainbow_speed = 2.0;
uniform float saturation_strength : hint_range(0.0, 1.0) = 1.0;

// Glow intensity for the lines
uniform float scanline_glow_strength : hint_range(0.0, 5.0) = 1.0;

vec3 rainbow(float t) {
    return 0.5 + 0.5 * cos(6.28318 * (t + vec3(0.0, 0.33, 0.67)));
}

void fragment() {
    vec4 tex = texture(TEXTURE, UV);
    float luminance = dot(tex.rgb, vec3(0.299, 0.587, 0.114));
    
    // 1. Rotation
    float angle = radians(scanline_angle_degrees);
    mat2 rotation = mat2(vec2(cos(angle), -sin(angle)), vec2(sin(angle), cos(angle)));
    vec2 rotated_uv = rotation * (UV - 0.5) + 0.5;
    
    // 2. Scanline calculation
    float scanline = pow(sin(rotated_uv.y * scanline_frequency + TIME * scanline_speed) * 0.5 + 0.5, scanline_thickness);
    float adaptive_scanline = scanline * luminance;
    
    // 3. Scanline-only Glow
    // We sample the adaptive_scanline in a cross-shape to "bleed" the light
    float blur_size = 0.002; // Adjust for spread distance
    float glow = adaptive_scanline;
    glow += texture(TEXTURE, UV + vec2(blur_size, 0.0)).a * 0.2; // Simple directional bleed
    glow += texture(TEXTURE, UV - vec2(blur_size, 0.0)).a * 0.2;
    
    // 4. Combine
    vec3 rainbow_color = rainbow((UV.x + UV.y) * 0.5 + (TIME * 0.1 * rainbow_speed));
    vec3 final_color = mix(tex.rgb, rainbow_color, luminance * saturation_strength);
    
    // Apply scanlines + glow
    final_color += (adaptive_scanline * scanline_intensity);
    final_color += (glow * scanline_glow_strength * adaptive_scanline);
    
    COLOR = vec4(final_color, tex.a);
}