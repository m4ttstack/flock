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
 * @default 1.8
 * @range 0.5, 8
 */
uniform float u_period;
/**
 * @label Tail
 * @default 0.35
 * @range 0.05, 1
 */
uniform float u_tail;
void main() {
  float x = gl_FragCoord.x / u_resolution.x;
  float head = fract(u_time / u_period) * (1.0 + u_tail);
  float behind = head - x;
  float a = 0.0;
  if (behind >= 0.0 && behind <= u_tail) {
    float t = 1.0 - behind / u_tail;
    a = t * t * t;
  }
  gl_FragColor = vec4(u_color * a, a);
}
