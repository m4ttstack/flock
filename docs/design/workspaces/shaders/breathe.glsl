precision mediump float;
/** @resolution */
uniform vec2 u_resolution;
/** @time */
uniform float u_time;
/**
 * @label Color
 * @color
 * @default #F7768E
 */
uniform vec3 u_color;
/**
 * @label Period (s)
 * @default 2.2
 * @range 0.5, 8
 */
uniform float u_period;
/**
 * @label Low
 * @default 0.15
 * @range 0, 1
 */
uniform float u_low;
/**
 * @label High
 * @default 0.75
 * @range 0, 1
 */
uniform float u_high;
void main() {
  float s = 0.5 + 0.5 * sin(u_time * 6.2831853 / u_period);
  float a = mix(u_low, u_high, s * s);
  gl_FragColor = vec4(u_color * a, a);
}
