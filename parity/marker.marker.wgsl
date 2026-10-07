@group(0) @binding(0) var<uniform> resolution: vec2<f32>;

@fragment
fn main(@builtin(position) pixel: vec4<f32>) -> @location(0) vec4<f32> {
    let x = i32(pixel.x);
    let y = i32(pixel.y);
    if (x < 16 && y < 16) { return vec4<f32>(1.0, 0.0, 0.0, 1.0); }
    if (x >= 241 && y < 16) { return vec4<f32>(0.0, 1.0, 0.0, 1.0); }
    if (x < 16 && y >= 113) { return vec4<f32>(0.0, 0.0, 1.0, 1.0); }
    if (x >= 241 && y >= 113) { return vec4<f32>(1.0, 1.0, 0.0, 1.0); }
    let uv = pixel.xy / resolution;
    return vec4<f32>(uv.x, uv.y, 1.0 - uv.x * 0.5, 1.0);
}
