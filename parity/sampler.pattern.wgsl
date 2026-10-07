@group(0) @binding(0) var<uniform> resolution: vec2<f32>;

@fragment
fn main(@builtin(position) pixel: vec4<f32>) -> @location(0) vec4<f32> {
    let uv = pixel.xy / resolution;
    let coords = vec2<i32>(uv * resolution);
    let checker = (coords.x + coords.y) & 1;
    return select(vec4<f32>(0.0, 0.0, 0.0, 1.0),
                  vec4<f32>(1.0, 1.0, 1.0, 1.0), checker == 1);
}
