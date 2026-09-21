# -*- coding: utf-8 -*-
"""生成局内数值调试面板的行目录 Data/debug_stat_catalog.json。

为什么生成而不是手写一千多行：手写一定会漏，漏掉的那一行等于面板在骗人。
两份来源都是实测：
  · Data/config/<域>.json —— 数值叶子（int/float/bool），数组按元素 id 定位。
    **域文件名直接当面板分类**（2026-09-20 config 拆域之后，文件名就是权威分类，
    不再自己另编一套，免得两套分类各说各话）。
  · Scripts/ 全量 Config.get_value 调用点 —— 每行记下「谁读它、在哪个函数读」。
    生效档由函数决定（见 TIER_RULES），一个路径被多处读时取**最粗**那一档：
    只要有一处是生成期读的，本局就看不到变化。

代码一处都不读的路径归 tier 5「未接线」，单独摆最后一类：改了没反应的行混在
可调行里，会让人以为面板坏了（本项目真踩过一次 —— 那行旋钮其实是死的）。
"""
import io, os, re, json, collections

PROJ = "D:/SteamPunkExtraction"
CFG_DIR = PROJ + "/Data/config"
OUT = PROJ + "/Data/debug_stat_catalog.json"
CALL = re.compile(r'get_value\(\s*"([a-z0-9_.%s]+)"')
CALL_CONCAT = re.compile(r'get_value\(\s*"([a-z0-9_.]+)"\s*\+')
# get_value("a.b." + str(i)) / (expr) —— 取到的是**整张数组**再下标，
# 这本身就是缓存点（取回去的那份是引用，改元素在场单位看得到，但取的那一刻定生死）
CALL_PREFIX = re.compile(r'get_value\(\s*"([a-z0-9_.]+)\."\s*\+')
FUNC = re.compile(r'^func\s+([A-Za-z0-9_]+)')
# 只是把路径列出来给人点的 UI，不是数值消费者 —— 留着会让"代码根本不读"的行
# 全部伪装成可调（面板自己就是一份路径清单）。
# 面板自己就是消费者的行（debug_stat_panel 被排除在扫描外，否则会全被判成"已接线"）
SELF_CONSUMED = {"debug.stat_panel_key"}
SCAN_EXCLUDE = {"debug_stat_panel", "settings_panel"}

# 域文件 -> 面板分类（None = 用文件名本身；这里只给中文名）
DOMAIN_CN = {
    "player": "角色", "combat": "战斗", "enemy": "敌人", "enemy_types": "敌人兵种",
    "animals": "中立生物", "map": "地图", "items": "资源掉落", "run": "局内节奏",
    "progression": "养成特性", "ambience": "氛围外观", "ui": "界面",
    "sprites": "贴图", "sprites_archer": "贴图·弓兵", "sprites_gunner": "贴图·枪手",
    "sprites_lancer": "贴图·长枪", "sprites_monk": "贴图·僧侣",
}
# 用户定的五大类归并：面板左树先按这 7 组，再按域文件分小页
BUCKET = {
    "char": ["player", "combat"], "enemy": ["enemy", "enemy_types", "animals"],
    "map": ["map", "items"], "trait": ["progression"], "run": ["run"],
    "look": ["ambience", "ui", "sprites", "sprites_archer", "sprites_gunner",
             "sprites_lancer", "sprites_monk"],
}
DOMAIN_BUCKET = {d: b for b, ds in BUCKET.items() for d in ds}
BUCKET_CN = {"char": "角色", "enemy": "敌人", "map": "地图资源", "trait": "升级特性",
             "run": "生存节奏", "look": "外观（折叠）", "misc": "其它"}

# ---------------------------------------------------------------- 生效档
# 按 file::func 精确判，规则按顺序命中即止。剩下的（每帧逻辑、getter、
# 事件回调）默认 1 档 —— 默认宽松是有意的：判错成 1 只是"没提示要重开"，
# 判错成 3 会让人白重开一局，后者代价大得多。
TIER_EXPLICIT = {
    # 4 = 启动读一次，重启进程才回头
    "<module>": 4, "main::_handle_cli": 4,
    "main::_dump_atlas_png": 4, "main::_render_map_preview": 4,
    # 3 = 生成期才读，重出击才生效
    "main::_generate_valid_map": 3, "main::_enter_run": 3, "main::_enter_base": 3,
    "main::_smoke_test": 3, "main3d::_generate_valid_map": 3, "main3d::_enter_run": 3,
    "main3d::_enter_base": 3, "main3d::_flow_test": 3, "main3d::_auto_capture": 3,
    "enemy_system::setup": 3, "enemy_system::_type_pool": 3,
    "animal_system::setup": 3, "animal_system::_type_pool": 3,
    "extraction_system::setup": 3, "extraction_system::_spawn_points": 3,
    "loot_system::setup": 3, "fog_system::setup": 3, "base_system::setup": 3,
    "map_render_3d::_build_flat_decor": 3, "map_render_3d::_ground_material": 3,
    "main3d::_build_player_visual": 3, "main3d::_setup_camera": 3,
    "camera_controller::_ready": 3, "iso_camera_3d::_ready": 3,
    "hit_direction_indicator::_ready": 3, "inventory_popup::_ready": 3,
    "main::_ready": 3, "main3d::_ready": 3, "entity_visual_3d::_cache_building_heights": 3,
    "entity_visual_3d::_cache_res_colors": 3, "enemy::_ready": 3,
    # 2 = 开局缓存，但面板会通知在场单位重算（refresh_debug_stats / apply_*）
    "enemy::_apply_numeric": 2, "enemy::_apply_type": 2, "enemy::_init_state_machine": 2,
    "enemy::_setup_phantom": 2, "enemy::refresh_debug_stats": 2,
    "animal::_apply_type_frames": 2, "building::_apply_sprite": 2,
    "building::_apply_footprint": 2, "loot_node::setup": 2, "loot_node::_apply_icon": 2,
    "loot_node::_apply_ring": 2, "enemy_hp_bar::_reload_cfg": 2,
    "fog_3d::configure": 2, "fog_3d::_build_plane": 2, "fog_3d::setup": 2,
    "display_settings::apply_display": 2, "display_settings::apply_audio": 2,
    "display_settings::apply_locale": 2, "display_settings::_apply_resolution": 2,
    "display_settings::current_window_mode": 2,
}
TIER_PATTERNS = [
    (r"^(_ready|setup|build|_build_\w+|_spawn\w*|_make_\w+|_render_\w+|_cache_\w+)$", 3),
    (r"^(_apply\w*|configure|enter|_reload_cfg|load_config|refresh_debug_stats)$", 2),
]


# 在场单位三脚本里"开局缓存"的值：面板每次写完都会对 player/enemies/animals
# 调 refresh_debug_stats()，所以它们其实当场就变 —— 判 3 档会谎报"要重出击"。
# 别的节点（相机 / HUD / 受击指示器）面板管不着，留在 3 档。
LIVE_UNIT_SCRIPTS = {"player", "enemy", "animal"}
LIVE_CACHE_FUNC = re.compile(r"^(_ready|setup|_apply\w*|refresh_debug_stats|_init_state_machine)$")


def tier_of_site(site):
    """site = 'file::func' -> 档位。函数部分单独判：
    顶层脚本加载期读（`xxx::<module>`）是 4 档，重启进程才回头。"""
    if site in TIER_EXPLICIT:
        return TIER_EXPLICIT[site]
    mod, fn = site.split("::", 1)
    if fn == "<module>":
        return 4
    if mod in LIVE_UNIT_SCRIPTS and LIVE_CACHE_FUNC.match(fn):
        return 2
    for pat, t in TIER_PATTERNS:
        if re.match(pat, fn):
            return t
    return 1


# 只喂抽样池的键：即使元素字典按引用发给在场单位，改它们也不会回头
POOL_ONLY_KEYS = {"weight", "share", "biome_weight", "min_size", "max_size", "total"}

TIER_NAME = {1: "立即", 2: "立即（面板会重算）", 3: "重出击才生效",
             4: "重启进程才生效", 5: "未接线（代码不读）"}

# ---------------------------------------------------------------- 中文名
KEY_CN = {
    "speed": "速度", "max_hp": "生命上限", "hp": "生命", "damage": "伤害", "defense": "防御",
    "contact_damage": "接触伤害", "chase_speed_multiplier": "追击倍率", "speed_mult": "速度倍率",
    "attack_range_px": "攻击距离", "range_px": "射程", "arc_degrees": "扇形角度",
    "max_targets": "最多目标", "windup_seconds": "出手前摇", "active_seconds": "判定时长",
    "recovery_seconds": "后摇", "cooldown_seconds": "冷却", "noise": "噪音",
    "crit_chance": "暴击率", "crit_multiplier": "暴击倍率", "variance": "伤害浮动",
    "hitstun_seconds": "受击硬直", "invincible_after_hit_seconds": "受击无敌",
    "knockback_speed": "击退初速", "knockback_px": "击退距离", "hit_knockback_px": "受击击退",
    "hit_stun_seconds": "受击微顿", "hit_flash_seconds": "受击泛红", "invincible": "无敌",
    "duration_seconds": "持续", "scan_interval_seconds": "索敌间隔", "enabled": "启用",
    "vision_cells": "视野格数", "vision_radius_cells": "视野格数",
    "ai_active_radius_cells": "AI活跃半径格", "blocked_by_walls": "被墙遮挡",
    "los_step": "视线采样步长", "lose_sight_seconds": "丢失视野等待",
    "min_duration_seconds": "最短出手时长", "count": "数量", "weight": "权重",
    "per_stack": "每层加成", "per_level": "每级加成", "max_level": "上限级数",
    "base": "基础值", "chance": "概率", "amount_min": "数量下限", "amount_max": "数量上限",
    "amount": "数量", "min_size": "最小团块", "max_size": "最大团块",
    "biome_weight": "群系权重", "share": "占比", "total": "总量", "value": "价值",
    "rarity": "稀有度", "per_node": "每节点", "harvest_time_seconds": "采集耗时",
    "meal_interval_seconds": "开饭间隔", "starvation_damage": "饥饿掉血",
    "starvation_interval_seconds": "饥饿结算间隔", "starvation_hp_floor": "饥饿血量底",
    "heal_per_food": "进食回血", "eat_cooldown_seconds": "进食冷却", "per_meal": "每顿扣除",
    "time_limit_seconds": "局时长", "stack_limit": "堆叠上限",
    "backpack_capacity": "背包格数", "height_ratio": "栏高比例", "min_height_px": "栏高下限",
    "max_height_px": "栏高上限", "scale": "缩放", "offset_y": "纵向偏移",
    "pixel_unit": "像素单位", "sprite_scale": "贴图缩放", "sprite_offset_y": "贴图纵偏",
    "sprite_pixel_unit": "贴图像素单位", "fps": "帧率", "frames": "帧数",
    "rot_degrees": "旋转角", "modulate": "染色", "additive": "叠加发光",
    "fade_out": "淡出时长", "z_index": "层级", "pierce": "穿透", "hit_radius": "命中半径",
    "muzzle_offset": "出膛偏移", "max_distance_px": "最大距离", "drop_spread_px": "掉落散开",
    "death_fade_seconds": "死亡淡出", "auto_enter_run": "自动进局", "time_scale": "计时倍速",
    "log_state_transitions": "打印状态切换", "smoke_test": "冒烟自检", "flow_test": "流程自检",
    "force_seed": "强制种子", "cell_px": "格子像素", "tile_px": "瓦片像素",
    "patrol_radius_cells": "巡逻半径格", "noise_sensitivity": "听力倍率",
    "max_members": "结伙上限", "flee_speed_mult": "逃跑倍率", "flee_radius_cells": "逃跑半径格",
    "wander_radius_cells": "游荡半径格", "radius_cells": "半径格", "interval_seconds": "间隔",
    "threshold": "阈值", "reference": "参考值", "investigate": "调查阈值",
    "alert_decay_seconds": "警觉衰减", "decay_seconds": "衰减时长", "radius_px": "半径像素",
    "width": "地图宽", "height": "地图高", "player_start": "出生点", "min_rects": "最少块数",
    "cancel_window_seconds": "取消窗口", "select_radius_px": "点选半径",
    "max_slots": "格位上限", "per_kill": "每次击杀",
}

# 实拍（1920x1080 全屏面板）里仍以英文键露面的那批，按出现频次补。
# 判据不是"好不好看"，是"这一行在屏幕上读不读得懂"：
# 数组表行的名字由面板自己拼（row_id + 所属段），这里只管叶子。
KEY_CN.update({
    # 通用量词
    "min": "下限", "max": "上限", "min_distance": "最近距离", "max_distance": "最远距离",
    "count_min": "数量下限", "count_max": "数量上限", "per_enemy": "每敌",
    "per_phantom": "每幻影", "max_multiplier": "倍率上限", "strength": "强度",
    "seconds": "秒数", "density": "密度", "exponent": "指数", "max_reduction": "减伤上限",
    "min_damage": "伤害下限", "size": "尺寸", "id": "编号", "name": "名称",
    # 相机 / 操作
    "zoom": "缩放", "zoom_min": "缩放下限", "zoom_max": "缩放上限", "zoom_step": "缩放步进",
    "zoom_smooth": "缩放平滑", "zoom_invert": "缩放反向", "zoom_at_cursor": "以光标缩放",
    "zoom_fit_bounds": "取景边界", "zoom_hud": "让位HUD", "pan_speed": "平移速度",
    "edge_pan_enabled": "边缘滚屏开关", "edge_pan_margin": "边缘滚屏边距",
    "edge_pan_speed_mult": "边缘滚屏倍率", "edge_pan_ignore_ui": "边缘滚屏忽略UI",
    "return_key": "回中键", "dodge_key": "闪避键", "eat_key": "进食键",
    "box_select_threshold_px": "框选阈值", "box_select_fill_alpha": "框选填充透明",
    "cam_distance": "机位距离", "pitch_deg": "俯仰角", "base_size": "基准尺寸",
    "interact_radius_cells": "交互半径格", "fit_camera_on_enter": "进局取景",
    # 受击方向 HUD
    "hit_direction_enabled": "受击方向开关", "hit_direction_radius_px": "受击方向半径",
    "hit_direction_arc_degrees": "受击方向扇形角", "hit_direction_band_px": "受击方向条宽",
    "hit_direction_max_marks": "受击方向最多标记", "hit_direction_fade_seconds": "受击方向淡出",
    "hit_direction_peak_alpha": "受击方向峰值透明", "hit_direction_segments": "受击方向分段",
    # 3D 显示
    "alpha_cut": "透明裁切", "anchor_offset_px": "挂点偏移", "brightness": "亮度",
    "shadow": "阴影", "shadow_alpha": "阴影透明", "shadow_size": "阴影尺寸",
    "shaded": "受光", "dither": "抖动", "world_height": "世界高度", "ring_radius": "光环半径",
    "debug_marker": "调试标记", "height_px": "高度像素", "width_px": "宽度像素",
    "flip_h_with_facing": "朝向镜像", "death_fps": "死亡帧率", "center_offset_y": "中心纵偏",
    "screen_fixed": "屏幕固定", "core_whiten": "核心泛白", "max_alpha": "透明上限",
    "min_scale": "缩放下限", "falloff": "衰减", "pulse_power": "脉冲强度",
    "spin_speed": "自转速度", "wobble_px": "晃动幅度", "orbit_y_scale": "环绕纵缩",
    "speed_sway": "摆动速度", "tint_white": "泛白染色", "curve": "曲线",
    "rise": "上浮", "hold": "保持", "fade": "淡出", "first_delay": "首段延迟",
    "start_zoom": "起始缩放", "end_zoom": "结束缩放", "on_level_up": "升级时",
    "on_select": "选中时", "text_size": "字号", "boost_flash": "提速泛光",
    # 声音 / AI
    "walk": "行走", "attack": "攻击", "idle": "待机", "dodge": "闪避", "shout": "喝令",
    "hurt": "受击", "dead": "死亡", "hit": "受击", "combat": "战斗", "alert": "警觉",
    "suspicious": "可疑", "animals": "生物", "enemies": "敌人", "player": "玩家",
    "footstep_interval_seconds": "脚步间隔", "alert_watch_interval_seconds": "警觉查看间隔",
    "max_alertness": "警觉上限", "ring_min_intensity": "声环最弱", "ring_alpha": "声环透明",
    "ring_duration_seconds": "声环时长", "ring_min_interval_seconds": "声环最短间隔",
    "hear_radius_cells": "听力半径格", "min_notice": "最弱可闻", "wall_attenuation": "隔墙衰减",
    "decay_ratio_per_second": "每秒衰减比", "self_to_world_per_second": "自身传世界每秒",
    "world_to_self_gain": "世界传自身增益", "los_step_cells": "视线采样步格",
    "patrol_idle_seconds": "巡逻停顿", "vision_blocked_by_walls": "视野被墙挡",
    "repath_interval_seconds": "重寻路间隔", "unstick_radius_cells": "脱困半径格",
    "snap_radius_cells": "吸附半径格", "follow_distance_px": "跟随距离",
    "join_radius_px": "归队距离", "max_target_distance_px": "目标最远",
    "min_target_distance_px": "目标最近", "sample_attempts": "采样次数",
    # 地图生成
    "biome_noise_frequency": "群系噪声频率", "biome_border_frequency": "群系边界频率",
    "biome_border_jitter": "群系边界抖动", "biome_edge_blend": "群系边缘混合",
    "biome_min_region_cells": "群系最小块格", "biome_remove_islands": "群系去孤岛",
    "biome_smooth_iterations": "群系平滑轮数", "biome_spread": "群系扩散",
    "cluster_noise_frequency": "矿脉噪声频率", "cluster_threshold": "矿脉阈值",
    "clear_spawn_radius_cells": "出生清空半径格", "veg_contrast": "植被对比",
    "noise_frequency": "噪声频率", "noise_threshold": "噪声阈值", "contrast": "对比",
    "saturation": "饱和", "jitter": "抖动", "tile_size": "瓦片尺寸",
    "width_cells": "宽度格", "min_dist_from_spawn_cells": "离出生最近格",
    "growth": "成长", "per_extraction": "每次撤离", "recruit_free": "免费招募",
    "drop_from_splits": "分裂掉落", "spawn_interval_seconds": "刷新间隔",
    "scatter_px": "散开像素", "chance_base": "基础概率", "chance_max": "概率上限",
    "decay_per_second": "每秒衰减", "graze": "吃草", "slow": "减速",
    # 资源 / 其它
    "gold": "金币", "wood": "木料", "stone": "石料", "iron": "铁", "oil": "石油",
    "food": "食物", "water": "水", "crystal": "水晶", "buff": "增益",
    "max_phantoms_per_owner": "每人幻影上限", "max_live_phantoms": "在场幻影上限",
    "resummon_interval_seconds": "再召唤间隔", "hp_ratio_of_owner": "生命比主人",
    "max_live_split_enemies": "在场分裂上限", "base_chance_at_or_above": "高于该值基础概率",
    "full_chance_at_or_below": "低于该值必中", "cache_seconds": "缓存时长",
    "pickup_retry_seconds": "拾取重试", "pickup_radius_px": "拾取半径",
    "ring_radius_px": "光环半径", "icon_px": "图标尺寸", "amount_per_node": "每节点产量",
    "min_distance_from_player_cells": "离玩家最近格", "min_reachable_ratio": "可达比例下限",
    "max_regen_attempts": "重生尝试", "swap_hp_step_ratio": "换血步进比",
    "spawn_at_minutes": "刷新分钟", "trigger_radius": "触发半径",
    "extraction_hold_seconds": "撤离按住时长", "warn_before_close_seconds": "关门前提醒",
    "building_cells": "建筑格", "map_size": "地图尺寸", "wall_height": "墙高",
    "floor_uv_scale": "地面UV缩放", "h3d": "3D高度",
    # 复查后仍以英文露面的最后一批
    "tree": "树", "rock": "石", "pebble": "碎石", "debris": "碎屑", "bush": "灌木",
    "frequency": "频率", "speed_multiplier": "速度倍率", "buffer_seconds": "输入缓冲",
    "dodge_cancel_enabled": "闪避取消开关", "dodge_cancel_after_seconds": "闪避可取消时刻",
    "clamp_to_walkable": "夹进可走区", "player_is_wall": "玩家算墙",
    "max_push_px_per_frame": "每帧最大推移", "separation": "分离推力",
    "hit_radius_px": "命中半径", "muzzle_offset_px": "出膛偏移",
    "blocked_give_up_frames": "受阻放弃帧数", "blocked_give_up_progress_px": "受阻放弃进度",
    "blocked_give_up_radius_px": "受阻放弃半径", "edge_pan": "边缘滚屏",
    "min_rect": "最小块", "spawn": "刷新", "loot": "掉落", "storage": "堆叠",
    "display": "显示", "nav": "导航", "noise": "噪音", "sources": "声源",
    "thresholds": "阈值", "levels": "档位", "supplies": "物资", "session": "局内",
    "hit_squash_amount": "受击挤压量", "show_seconds": "显示时长",
    "active_radius_cells": "生效半径格", "spawn_radius_px": "生成半径",
    "max_speed_multiplier": "最大速度倍率", "move_speed": "移动速度",
    "speed_sway2": "速度摆动 2", "speed_sway_hz": "速度摆动频率", "speed_sway_hz2": "速度摆动频率 2",
    "min_distance_between_points_cells": "点间最小距离格",
    "min_distance_from_spawn_cells": "距出生点最小格", "size_px": "尺寸",
})


def cn_key(k):
    return KEY_CN.get(k, k)


def num(v):
    return isinstance(v, bool) or isinstance(v, (int, float))


# ---------------------------------------------------------------- 扫读取点
def scan_reads():
    """-> ({路径: set(site)}, {模板: set(site)}, {词干: set(site)})
    整份文本扫而不是逐行：`Config.get_value(` 和字面量经常换行写，逐行会漏
    （map_generator 的 biome_weights 就是这么被误判成"代码不读"的）。"""
    by_path = collections.defaultdict(set)
    templates = collections.defaultdict(set)
    stems = collections.defaultdict(set)
    for dirpath, dirs, files in os.walk(PROJ + "/Scripts"):
        dirs[:] = [d for d in dirs if d != ".godot"]
        for fn in files:
            if not fn.endswith(".gd"):
                continue
            mod = fn[:-3]
            if mod in SCAN_EXCLUDE or mod == "config_loader":
                continue
            src = io.open(os.path.join(dirpath, fn), encoding="utf-8").read()
            # 偏移 -> 所在函数：按 func 行的位置二分
            # ⚠ 必须 re.M：整份文本扫时 ^ 默认只认文件开头，
            # 少了 MULTILINE 每个读取点都会算成 <module>，档位全塌。
            bounds = [(m.start(), m.group(1)) for m in re.finditer(
                r'^func\s+([A-Za-z0-9_]+)', src, re.M)]
            bounds.append((len(src), "<module>"))

            def func_at(pos):
                cur = "<module>"
                for b, name in bounds:
                    if b > pos:
                        return cur
                    cur = name
                return cur

            for rx, kind in ((CALL, "call"), (CALL_CONCAT, "concat"), (CALL_PREFIX, "prefix")):
                for m in rx.finditer(src):
                    site = "%s::%s" % (mod, func_at(m.start()))
                    p = m.group(1)
                    if kind == "concat":
                        if p.endswith("."):
                            templates[p + "%s"].add(site)
                        else:
                            stems[p].add(site)   # "sprites_" + set_name
                    elif kind == "prefix":
                        by_path[p].add(site)     # "map.biome_weights." + str(i)
                    elif "%s" in p or "%d" in p:
                        templates[p].add(site)
                    else:
                        by_path[p].add(site)
    return by_path, templates, stems


def template_hits(path, templates):
    """键名动态拼接的读法（`"combat.attack.%s"` / `"combat.attack." + key`）：
    模板段数可以**少于**路径段数，按前缀匹配 —— 否则整张 `combat.attack.*`
    都会被误判成"代码不读"。返回命中的读取点。"""
    seg = path.split(".")
    hit = set()
    for t, sites in templates.items():
        ts = t.split(".")
        if len(ts) > len(seg):
            continue
        if all(a in ("%s", "%d") or a == b for a, b in zip(ts, seg)):
            hit |= sites
    return hit



def step_for(v):
    if isinstance(v, bool):
        return None
    if isinstance(v, int):
        return 1
    return 0.01 if abs(v) < 10 else 0.1


def main():
    reads, templates, stems = scan_reads()
    rows = []
    for fn in sorted(os.listdir(CFG_DIR)):
        if not fn.endswith(".json"):
            continue
        domain = fn[:-5]
        tree = json.load(io.open(os.path.join(CFG_DIR, fn), encoding="utf-8-sig"))

        def walk(o, parts, idpath):
            if isinstance(o, dict):
                for k, v in o.items():
                    if k != "_comment":
                        walk(v, parts + [k], idpath)
            elif isinstance(o, list):
                for i, v in enumerate(o):
                    rid = str(v.get("id") or v.get("name") or i) if isinstance(v, dict) else None
                    # 纯数字数组（biome_weights 那种）按下标寻址，不配 id
                    walk(v, parts + [str(i)], (idpath or []) + ([rid] if rid else []))
            else:
                if not num(o):
                    return
                path = ".".join(parts)
                seg = path.split(".")
                sites = set(reads.get(path, ()))
                # 数组元素：代码多是「取整张表 + el.get(key)」，且那张表按**引用**发给
                # 每只在场单位（Enemy._type_cfg 就是它本身），所以元素行取**最细**的一档
                # —— 抽样池那一次是生成期读，不代表单位不再回头看它。
                if idpath:
                    tbl = ".".join(parts[:len(parts) - len(idpath) - 1])
                    sites |= set(reads.get(tbl, ()))
                if not sites:
                    sites |= template_hits(path, templates)
                if not sites:
                    # "sprites_" + set_name 这种词干拼法：顶层段以它开头就算同一处读
                    for st, ss in stems.items():
                        if seg[0].startswith(st):
                            sites |= ss
                            break
                if not sites:
                    # 还有种写法：整棵子树取走再 .get(键)。那就跟着最近的祖先算。
                    for n in range(len(seg) - 1, 0, -1):
                        anc = ".".join(seg[:n])
                        if anc in reads:
                            sites |= reads[anc]
                            break
                        if anc in templates:
                            sites |= templates[anc]
                            break
                if not sites:
                    tier = 1 if path in SELF_CONSUMED else 5
                elif idpath:
                    tier = min(tier_of_site(s) for s in sites)
                    if seg[-1] in POOL_ONLY_KEYS:
                        tier = max(tier, 3)
                else:
                    tier = max(tier_of_site(s) for s in sites)
                rows.append({
                    "path": path,
                    "cat": DOMAIN_BUCKET.get(domain, "misc"), "domain": domain,
                    "group": "/".join(idpath[:-1]) if idpath and len(idpath) > 1 else "",
                    "row_id": idpath[-1] if idpath else "",
                    "label": ("#%s" % seg[-1] if seg[-1].isdigit() else cn_key(seg[-1])),
                    "tier": tier,
                    "type": "bool" if isinstance(o, bool) else ("int" if isinstance(o, int) else "float"),
                    "factory": o, "step": step_for(o),
                    "sites": sorted(sites)[:3],
                })

        for k, v in tree.items():
            walk(v, [k], None)

    order = ["char", "enemy", "map", "trait", "run", "look", "misc"]
    for r in rows:
        seg = r["path"].split(".")
        first_list = next((i for i, s in enumerate(seg) if s.isdigit()), None)
        # 纯字典路径能走 Config 的内存覆盖层（clear_override 就能还原）；
        # 一旦跨过数组，点路径根本到不了（_probe 只穿字典），只能就地改共享容器。
        r["via"] = "override" if first_list is None else "inplace"
        r["base"] = ".".join(seg[:first_list]) if first_list is not None else r["path"]
    rows.sort(key=lambda r: (order.index(r["cat"]), r["tier"], r["domain"],
                             r["group"], r["path"]))
    io.open(OUT, "w", encoding="utf-8").write(json.dumps(
        {"tiers": {str(k): v for k, v in TIER_NAME.items()},
         "buckets": BUCKET_CN, "rows": rows},
        ensure_ascii=False, separators=(",", ":")))

    print("生成 %d 行 -> %s（%d KB）" % (len(rows), OUT, os.path.getsize(OUT) // 1024))
    for label, key in (("分类", "cat"), ("生效档", "tier"), ("域", "domain")):
        c = collections.Counter(r[key] for r in rows)
        print("\n按%s:" % label, dict(c))
    print("\n各分类里可调（tier1~3）的行数:")
    playable = [r for r in rows if r["tier"] <= 3]
    print("  ", collections.Counter(r["cat"] for r in playable))
    print("\n写入路线: override(内存覆盖层) %d ｜ inplace(就地改共享数组) %d" % (
        sum(1 for r in rows if r["via"] == "override"),
        sum(1 for r in rows if r["via"] == "inplace")))
    print("\n每档抽样（看归类对不对）：")
    for t in (1, 2, 3, 4, 5):
        for r in [x for x in rows if x["tier"] == t][:3]:
            print("  [%d] %-52s %-14s %s" % (t, r["path"], r["label"], r["sites"][:1]))


main()
