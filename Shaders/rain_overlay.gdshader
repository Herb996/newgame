shader_type canvas_item;
// ============================================================
// rain_overlay —— 屏幕雨幕（DEV LOG.02 步骤 6）
//
// 宿主是 CanvasLayer 下一张全屏 ColorRect：压在世界上、HUD 之下，只调制颜色，
// 不吃鼠标（mouse_filter 由 weather_system 设成 IGNORE）。
//
// 两步：① 整屏 darken（雨天压暗，参考值 0.9）② 朝雨幕蓝灰 mix（参考 rain_opacity 0.15）。
// ② 用 mix 而不是加法：加法会把暗部顶成发灰的雾，mix 保留对比。
//
// ⚠ canvas_item 的 fragment() 里不能写 return（Godot 4 直接编译失败 → 整层退化成
//   ColorRect 白纹理，画面全白）。所有分支只能用赋值表达。
// ============================================================

uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;
uniform vec4 tint : source_color = vec4(0.56, 0.69, 0.80, 1.0);
uniform float opacity : hint_range(0.0, 1.0) = 0.15;
uniform float darken : hint_range(0.0, 2.0) = 0.90;
// 底部略重：雨幕在贴近地面的地方更厚，视线往远处才透。
uniform float vertical_bias : hint_range(0.0, 1.0) = 0.35;

void fragment() {
	vec4 c = texture(screen_texture, SCREEN_UV);
	c.rgb *= darken;
	float o = opacity * (1.0 + vertical_bias * (SCREEN_UV.y * 2.0 - 1.0));
	COLOR = vec4(mix(c.rgb, tint.rgb, clamp(o, 0.0, 1.0)), 1.0);
}
