# -*- coding: utf-8 -*-
"""给 ep_spear_goblin 补切「_Attack Strong」重击套，并合并进 config 的 attack 数组。

只动 ep_spear_goblin 的 attack 帧，不动其他兵种、不动 traits/ai（避免清掉特性迁移）。
切片规律：Tiny Swords 帧宽 = 横条高度 H，帧数 = W // H。
"""
import json
import os

from PIL import Image

PROJ = r"D:\SteamPunkExtraction"
SRC = (r"D:\Tiny-Warcamp\Tiny-Warcamp-main\TinyResources"
       r"\Tiny Swords (Enemy Pack)\Tiny Swords (Enemy Pack)\Enemy Pack\Enemies"
       r"\Goblin Raiders\Spear Goblin")
DST = os.path.join(PROJ, "Assets", "Art", "Sprites", "Units", "ep_spear_goblin")
CONFIG = os.path.join(PROJ, "Data", "config.json")
RES_PREFIX = "res://Assets/Art/Sprites/Units/ep_spear_goblin/"
TARGET = "ep_spear_goblin"
STRONG_NAME = "Spear Goblin_Attack Strong.png"


def main() -> int:
    # 找 Strong 条带
    strong_path = None
    for f in sorted(os.listdir(SRC)):
        if f.endswith(".png") and not f.endswith(".import") and "_Attack Strong" in f:
            strong_path = os.path.join(SRC, f)
            break
    if strong_path is None:
        print("[skip] 找不到 %s 的 _Attack Strong 条带" % TARGET)
        return 0

    # 现有 attack 帧数（Fast 已切在 attack_00..NN）
    cfg = json.load(open(CONFIG, encoding="utf-8-sig"))
    types = cfg["enemy_types"]["types"]
    sg = next((t for t in types if t["id"] == TARGET), None)
    if sg is None:
        print("[skip] config 里没有 %s" % TARGET)
        return 0
    existing = list(sg.get("attack", []))
    start = len(existing)
    print("现有 attack 帧: %d (将从 attack_%02d 续切 Strong)" % (start, start))

    # 切 Strong
    sheet = Image.open(strong_path).convert("RGBA")
    W, H = sheet.size
    if W % H != 0:
        print("[错误] Strong 条带宽 %d 不能被高 %d 整除" % (W, H))
        return 1
    n = W // H
    os.makedirs(DST, exist_ok=True)
    new_paths = []
    for i in range(n):
        fr = sheet.crop((i * H, 0, (i + 1) * H, H))
        name = "attack_%02d.png" % (start + i)
        fr.save(os.path.join(DST, name))
        new_paths.append(RES_PREFIX + name)
    print("切出 Strong 帧: %d -> %s" % (n, new_paths[0]))

    # 合并进 config（Fast 在前、Strong 在后，连续）
    sg["attack"] = existing + new_paths
    with open(CONFIG, "w", encoding="utf-8-sig", newline="\n") as fh:
        json.dump(cfg, fh, ensure_ascii=False, indent=2)
    print("config %s.attack 现共 %d 帧 (Fast %d + Strong %d)"
          % (TARGET, len(sg["attack"]), start, n))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
