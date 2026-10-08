@group(0) @binding(0) var volTex: texture_3d<f32>;
@group(0) @binding(1) var volSampler: sampler;
@fragment
fn main(@builtin(position) pixel: vec4<f32>) -> @location(0) vec4<f32> {
  let x = i32(pixel.x) % 8;
  let y = i32(pixel.y) % 8;
  let z = (i32(pixel.x) / 32) % 8;
  let coord = (vec3<f32>(f32(x), f32(y), f32(z)) +
    vec3<f32>(0.37, 0.61, 0.42)) / 8.0;
  return textureSampleLevel(volTex, volSampler, coord, 0.0);
}
