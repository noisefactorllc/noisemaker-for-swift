@group(0) @binding(0) var<uniform> resolution: vec2<f32>;
@group(0) @binding(1) var firstTex: texture_2d<f32>;
@group(0) @binding(2) var secondTex: texture_2d<f32>;

@fragment
fn main(@builtin(position) pixel: vec4<f32>) -> @location(0) vec4<f32> {
    let coords = vec2<i32>(pixel.xy);
    let first = textureLoad(firstTex, coords, 0);
    let second = textureLoad(secondTex, coords, 0);
    let uv = pixel.xy / resolution;
    return vec4<f32>(first.r, second.g, 1.0 - uv.x, 1.0);
}
