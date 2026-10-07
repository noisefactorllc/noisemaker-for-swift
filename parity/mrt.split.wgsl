@group(0) @binding(0) var<uniform> resolution: vec2<f32>;

struct SplitOutput {
    @location(0) first: vec4<f32>,
    @location(1) second: vec4<f32>,
}

@fragment
fn main(@builtin(position) pixel: vec4<f32>) -> SplitOutput {
    let uv = pixel.xy / resolution;
    return SplitOutput(vec4<f32>(uv.x, 0.0, 0.0, 1.0),
                       vec4<f32>(0.0, uv.y, 0.0, 1.0));
}
