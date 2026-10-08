@group(0) @binding(0) var volumeOut: texture_storage_3d<rgba8unorm, write>;
@compute @workgroup_size(4, 4, 4)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
  if (any(gid >= vec3<u32>(8u, 8u, 8u))) { return; }
  textureStore(volumeOut, vec3<i32>(gid), vec4<f32>(f32(gid.x) / 7.0, f32(gid.y) / 7.0, f32(gid.z) / 7.0, 1.0));
}
