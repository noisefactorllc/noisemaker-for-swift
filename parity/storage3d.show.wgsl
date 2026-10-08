@group(0) @binding(0) var volTex: texture_3d<f32>;
@fragment
fn main(@builtin(position) pixel: vec4<f32>) -> @location(0) vec4<f32> {
  let x = i32(pixel.x) % 8;
  let y = i32(pixel.y) % 8;
  let z = (i32(pixel.x) / 32 + i32(pixel.y) / 32) % 8;
  return textureLoad(volTex, vec3<i32>(x, y, z), 0);
}
