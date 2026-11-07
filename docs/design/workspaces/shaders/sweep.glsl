precision mediump float;
/** @resolution */
uniform vec2 u_resolution;
/** @time */
uniform float u_time;
/**
 * @label Color
 * @color
 * @default #E0AF68
 */
uniform vec3 u_color;
/**
 * @label Period (s)
 * @default 2.6
 * @range 0.5, 8
 */
uniform float u_period;
/**
 * @label Resting opacity
 * @default 0.12
 * @range 0, 1
 */
uniform float u_base;
/**
 * @label Glint width
 * @default 0.18
 * @range 0.02, 1
 */
uniform float u_width;
void main() {
  float x = gl_FragCoord.x / u_resolution.x;
  float pos = fract(u_time / u_period) * (1.0 + 2.0 * u_width) - u_width;
  float d = (x - pos) / u_width;
  float glint = exp(-d * d * 3.0);
  float a = clamp(u_base + glint * 0.85, 0.0, 1.0);
  gl_FragColor = vec4(u_color * a, a);
}
