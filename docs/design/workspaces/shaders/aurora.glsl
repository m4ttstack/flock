precision mediump float;
/** @resolution */
uniform vec2 u_resolution;
/** @time */
uniform float u_time;
/**
 * @label Color A
 * @color
 * @default #E0AF68
 */
uniform vec3 u_a;
/**
 * @label Color B
 * @color
 * @default #BB9AF7
 */
uniform vec3 u_b;
/**
 * @label Opacity
 * @default 0.55
 * @range 0, 1
 */
uniform float u_alpha;
void main() {
  float x = gl_FragCoord.x / u_resolution.x;
  float w = 0.5 + 0.5 * sin((x * 2.0 - u_time * 0.25) * 6.2831853);
  float v = 0.5 + 0.5 * sin((x * 3.3 + u_time * 0.17) * 6.2831853);
  vec3 c = mix(u_a, u_b, w);
  float a = u_alpha * (0.35 + 0.65 * v);
  gl_FragColor = vec4(c * a, a);
}
