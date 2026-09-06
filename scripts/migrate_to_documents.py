# 一次性迁移脚本：把 %APPDATA% 的应用数据搬到 E:\Documents\TutorChat，并升级到新数据结构
# 前置：原始数据已备份到 E:\Downloads\Cache\tutor_chat_app_backup_20260906
# 动作：
#   1. 整体复制 %APPDATA%\...\tutor_chat_app -> E:\Documents\TutorChat
#   2. 每门课程：TUTOR/*.json 平铺到课程根目录，删除 TUTOR/
#   3. 删除 CHAT/2026-08-17-第3课.jsonl（仅 1 行 meta 的空壳，被散落的 08-06 真文件取代）
#   4. 课程根目录散落的课次文件移入 CHAT/
#   5. 全部 message 行补 phase=teaching；SOCIAL/*.jsonl 的 message 行补 phase=social
#      追加到对应课次文件末尾，然后删除 SOCIAL/
# 运行：uv run python scripts/migrate_to_documents.py
import json
import shutil
import sys
from pathlib import Path

SRC = Path(r"C:\Users\zooms\AppData\Roaming\com.github.zooms233\tutor_chat_app")
DST = Path(r"E:\Documents\TutorChat")

# 目标处理：直接重建（源数据在 %APPDATA% 仍在，且另有 E:\Downloads\Cache 备份）
# 重跑本脚本时先删掉上次的迁移产物


def lesson_num(stem: str) -> int:
    """从文件名提取课次号：'2026-08-06-第3课' -> 3"""
    return int(stem.split("第")[-1].replace("课", ""))


# 1. 整体复制
if DST.exists():
    shutil.rmtree(DST)
shutil.copytree(SRC, DST)
print(f"已复制 {SRC} -> {DST}")

# 2~5. 逐课程结构迁移
for course in (DST / "课程").iterdir():
    if not course.is_dir():
        continue
    print(f"\n课程：{course.name}")

    # 2. TUTOR/ 平铺
    tutor_dir = course / "TUTOR"
    if tutor_dir.exists():
        for f in tutor_dir.glob("*.json"):
            shutil.move(str(f), course / f.name)
        tutor_dir.rmdir()
        print("  TUTOR/ 已平铺")

    chat_dir = course / "CHAT"
    chat_dir.mkdir(exist_ok=True)

    # 3. SOCIAL 消息读入内存（只取 message 行，meta 里的旧群名丢弃）
    social_by_lesson: dict[int, list[str]] = {}
    social_dir = course / "SOCIAL"
    if social_dir.exists():
        for f in sorted(social_dir.glob("*.jsonl")):
            msgs = []
            for line in f.read_text(encoding="utf-8").splitlines():
                if not line.strip():
                    continue
                row = json.loads(line)
                if row.get("type") == "message":
                    row["phase"] = "social"
                    msgs.append(json.dumps(row, ensure_ascii=False))
            social_by_lesson[lesson_num(f.stem)] = msgs
        shutil.rmtree(social_dir)
        print("  SOCIAL/ 已并入待写列表")

    # 3b. 删除已知空壳课次文件（仅 1 行 meta，无任何消息）
    for f in sorted(chat_dir.glob("*.jsonl")):
        if f.name == "2026-08-17-第3课.jsonl" and len(
            f.read_text(encoding="utf-8").splitlines()
        ) == 1:
            f.unlink()
            print("  已删除空壳：CHAT/2026-08-17-第3课.jsonl")

    # 4. 课程根目录散落的课次文件移入 CHAT/（只匹配课次命名，避免误伤 PROGRESS.jsonl）
    for f in course.glob("*第*课.jsonl"):
        shutil.move(str(f), chat_dir / f.name)
        print(f"  已移入 CHAT/{f.name}")

    # 5. 每个课次文件：旧 message 行补 phase=teaching，末尾追加对应 social 消息
    for f in sorted(chat_dir.glob("*.jsonl")):
        lines = [l for l in f.read_text(encoding="utf-8").splitlines() if l.strip()]
        out = []
        for line in lines:
            row = json.loads(line)
            if row.get("type") == "message" and "phase" not in row:
                row["phase"] = "teaching"
                out.append(json.dumps(row, ensure_ascii=False))
            else:
                out.append(line)
        n = lesson_num(f.stem)
        if n in social_by_lesson:
            out.extend(social_by_lesson[n])
        f.write_text("\n".join(out) + "\n", encoding="utf-8")
        print(f"  {f.name}: 共 {len(out)} 行（meta 1 + 其余消息）")

print("\n迁移完成")
