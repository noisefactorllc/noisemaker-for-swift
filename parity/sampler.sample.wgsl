@group(0) @binding(0) var<uniform> resolution: vec2<f32>;
@group(0) @binding(1) var inputTex: texture_2d<f32>;
@group(0) @binding(2) var inputSampler: sampler;

@fragment
fn main(@builtin(position) pixel: vec4<f32>) -> @location(0) vec4<f32> {
    let uv = (pixel.xy + vec2<f32>(0.25, 0.25)) / resolution;
    return textureSample(inputTex, inputSampler, uv);
}
