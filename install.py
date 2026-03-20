#!/usr/bin/env python3
"""
audit-harness 安装向导
======================
交互式安装脚本，在目标项目中完成 audit-harness 的全部配置。
安装完成后 /start, /end, /recover, /report-daily 立即可用。

用法:
    python /path/to/audit-harness/install.py           # 在当前目录安装
    python /path/to/audit-harness/install.py /my/proj  # 指定目标项目
"""
from __future__ import annotations

import glob
import json
import os
import shutil
import sys
from pathlib import Path

# ==========================================
# 路径
# ==========================================
HARNESS_ROOT = Path(__file__).parent.resolve()
SKILLS_SRC = HARNESS_ROOT / "skills"
LIB_SRC = HARNESS_ROOT / "lib"
TEMPLATES_SRC = HARNESS_ROOT / "templates"


def _green(s):  return f"\033[92m{s}\033[0m"
def _yellow(s): return f"\033[93m{s}\033[0m"
def _red(s):    return f"\033[91m{s}\033[0m"
def _bold(s):   return f"\033[1m{s}\033[0m"
def _dim(s):    return f"\033[2m{s}\033[0m"


def ask(prompt: str, default: str = "") -> str:
    hint = f" [{default}]" if default else ""
    val = input(f"  {prompt}{hint}: ").strip()
    return val if val else default


def ask_yn(prompt: str, default: bool = True) -> bool:
    hint = "Y/n" if default else "y/N"
    val = input(f"  {prompt} ({hint}): ").strip().lower()
    if not val:
        return default
    return val in ("y", "yes")


def scan_py_files(project: Path, limit: int = 20) -> list[str]:
    """扫描项目根目录下的 .py 文件，按修改时间排序"""
    files = []
    for p in project.glob("*.py"):
        if p.name.startswith("_") or p.name.startswith("."):
            continue
        files.append((p.name, p.stat().st_mtime))
    files.sort(key=lambda x: -x[1])
    return [f[0] for f in files[:limit]]


def detect_env(project: Path) -> dict:
    """检测目标项目环境"""
    return {
        "audit_context": (project / "audit_context.py").exists(),
        "audit_config": (project / "audit_config.py").exists(),
        "runs_dir": (project / "runs").is_dir(),
        "claude_md": (project / "CLAUDE.md").exists(),
        "claude_md_has_audit": _claude_md_has_audit(project),
        "skills_dir": (project / ".claude" / "skills").is_dir(),
        "is_git": (project / ".git").is_dir(),
    }


def _claude_md_has_audit(project: Path) -> bool:
    cm = project / "CLAUDE.md"
    if not cm.exists():
        return False
    content = cm.read_text(encoding="utf-8")
    return "[AUDIT]" in content and "audit_blocks" in content


# ==========================================
# Step 1: 环境检测
# ==========================================
def step1_detect(project: Path) -> dict:
    print()
    print(_bold("=" * 60))
    print(_bold("  audit-harness 安装向导"))
    print(_bold("=" * 60))
    print()
    print(f"  目标项目: {project}")
    print()

    env = detect_env(project)

    print("  环境检测:")
    items = [
        ("Git 仓库", env["is_git"]),
        ("audit_context.py", env["audit_context"]),
        ("audit_config.py", env["audit_config"]),
        ("runs/ 目录", env["runs_dir"]),
        ("CLAUDE.md", env["claude_md"]),
        ("CLAUDE.md 审计规范", env["claude_md_has_audit"]),
        (".claude/skills/", env["skills_dir"]),
    ]
    for name, exists in items:
        status = _green("✅ 已存在") if exists else _yellow("❌ 需要安装")
        print(f"    {status}  {name}")

    print()
    if all(v for v in env.values()):
        print(_green("  所有组件已安装。重新运行将更新到最新版本。"))
    else:
        needs = sum(1 for v in env.values() if not v)
        print(f"  需要安装/配置 {needs} 个组件。")

    return env


# ==========================================
# Step 2: 收集项目配置
# ==========================================
def step2_collect(project: Path) -> dict:
    print()
    print(_bold("--- Step 2: 项目配置 ---"))
    print()

    # 核心脚本
    print("  " + _dim("核心脚本: 环境快照时计算这些文件的哈希，用于追踪配置变化"))
    choice = ask("输入核心脚本文件名(逗号分隔) 或 'scan' 自动扫描", "scan")

    if choice.lower() == "scan":
        py_files = scan_py_files(project)
        if py_files:
            print(f"    扫描到 {len(py_files)} 个 .py 文件:")
            for i, f in enumerate(py_files):
                print(f"      {i+1}. {f}")
            selected = ask("选择文件编号(逗号分隔) 或 'all' 或直接回车跳过", "")
            if selected.lower() == "all":
                core_scripts = py_files
            elif selected:
                indices = [int(x.strip()) - 1 for x in selected.split(",") if x.strip().isdigit()]
                core_scripts = [py_files[i] for i in indices if 0 <= i < len(py_files)]
            else:
                core_scripts = []
        else:
            print("    未扫描到 .py 文件")
            core_scripts = []
    else:
        core_scripts = [s.strip() for s in choice.split(",") if s.strip()]

    print()

    # 核心资产
    print("  " + _dim("核心资产: 模型文件、配置文件等需要追踪哈希的文件"))
    assets_input = ask("输入资产文件名(逗号分隔) 或 'none'", "none")
    core_assets = [] if assets_input.lower() == "none" else [s.strip() for s in assets_input.split(",") if s.strip()]

    print()

    # Prompt 模板
    print("  " + _dim("Prompt 模板: 如果项目使用 AI Prompt，提供 glob 模式"))
    prompt_glob = ask("glob 模式(如 'prompts/*.txt') 或 'none'", "none")
    if prompt_glob.lower() == "none":
        prompt_glob = ""

    print()

    # 告警规则
    print("  告警规则配置:")
    print("    1. 使用默认规则（仅数据完整性校验）")
    print("    2. 稍后手动编辑 audit_config.py")
    alert_choice = ask("选择", "1")

    return {
        "core_scripts": core_scripts,
        "core_assets": core_assets,
        "prompt_glob": prompt_glob,
        "alert_choice": alert_choice,
    }


# ==========================================
# Step 3: 安装核心文件
# ==========================================
def step3_install_core(project: Path, config: dict, env: dict):
    print()
    print(_bold("--- Step 3: 安装核心文件 ---"))
    print()

    # audit_context.py
    src = LIB_SRC / "audit_context.py"
    dst = project / "audit_context.py"
    if env["audit_context"] and not ask_yn("audit_context.py 已存在，覆盖?", False):
        print(f"    ⏭️  跳过 audit_context.py")
    else:
        shutil.copy2(src, dst)
        # 修正 PROJECT_ROOT 为项目根目录（而非 lib/）
        content = dst.read_text(encoding="utf-8")
        content = content.replace(
            "PROJECT_ROOT = Path(__file__).parent",
            "PROJECT_ROOT = Path(__file__).parent",
        )
        dst.write_text(content, encoding="utf-8")
        print(f"    {_green('✅')} audit_context.py → {dst}")

    # audit_config.py
    dst_config = project / "audit_config.py"
    if env["audit_config"] and not ask_yn("audit_config.py 已存在，覆盖?", False):
        print(f"    ⏭️  跳过 audit_config.py")
    else:
        _generate_config(dst_config, config)
        print(f"    {_green('✅')} audit_config.py → {dst_config} (已填入你的配置)")

    # runs/ 目录
    runs_dir = project / "runs" / "daily"
    runs_dir.mkdir(parents=True, exist_ok=True)
    print(f"    {_green('✅')} runs/ 目录已创建")

    # runs/.gitignore
    gitignore = project / "runs" / ".gitignore"
    if not gitignore.exists():
        gitignore.write_text(
            "# 审计数据：大文件不入库，保留目录结构\n"
            "*.jsonl\n"
            "*.json\n"
            "!index.json\n"
            "# 日报和周报保留\n"
            "!daily/\n"
            "!weekly/\n"
        )
        print(f"    {_green('✅')} runs/.gitignore 已创建")


def _generate_config(path: Path, config: dict):
    """基于用户输入生成 audit_config.py"""
    scripts_str = ",\n    ".join(f'"{s}"' for s in config["core_scripts"])
    assets_str = ",\n    ".join(f'"{s}"' for s in config["core_assets"])
    prompt_glob = config["prompt_glob"]

    content = f'''"""
audit_config.py — 项目专属审计配置
自动生成 by audit-harness install.py
"""

CORE_SCRIPTS = [
    {scripts_str}
]

CORE_ASSETS = [
    {assets_str}
]

PROMPT_TEMPLATE_GLOB = "{prompt_glob}"

def _safe_div(a, b):
    return a / b if b else 0

ALERT_RULES = [
    {{
        "id": "output_integrity",
        "condition": lambda m: (
            m.get("output", {{}}).get("total_records") is not None
            and m.get("cleaning", {{}}).get("total_input") is not None
            and m.get("cleaning", {{}}).get("total_deleted") is not None
            and m["output"]["total_records"]
            != m["cleaning"]["total_input"] - m["cleaning"]["total_deleted"]
        ),
        "level": "CRITICAL",
        "message": "输出记录数 ≠ 输入 - 删除，存在数据丢失",
    }},
]
'''
    path.write_text(content, encoding="utf-8")


# ==========================================
# Step 4: 安装 Skills
# ==========================================
def step4_install_skills(project: Path, env: dict):
    print()
    print(_bold("--- Step 4: 安装 Skills ---"))
    print()

    skills_dst = project / ".claude" / "skills"
    skills_dst.mkdir(parents=True, exist_ok=True)

    installed = 0
    for skill_dir in sorted(SKILLS_SRC.iterdir()):
        if not skill_dir.is_dir():
            continue
        name = skill_dir.name
        if name == "audit-init":
            continue  # 不复制安装向导自身
        dst = skills_dst / name
        if dst.exists():
            shutil.rmtree(dst)
        shutil.copytree(skill_dir, dst)
        print(f"    {_green('✅')} /{name.replace('audit-', '')} → {dst.relative_to(project)}")
        installed += 1

    print(f"\n    已安装 {installed} 个 Skills")


# ==========================================
# Step 5: 注入 CLAUDE.md
# ==========================================
def step5_inject_claude_md(project: Path, env: dict, auto: bool = False):
    print()
    print(_bold("--- Step 5: 配置 CLAUDE.md ---"))
    print()

    audit_section = (TEMPLATES_SRC / "CLAUDE.md.audit-section").read_text(encoding="utf-8")
    claude_md = project / "CLAUDE.md"

    if not env["claude_md"]:
        claude_md.write_text(
            f"# {project.name}\n\n"
            f"> 项目描述（请填写）\n\n"
            f"---\n\n"
            f"{audit_section}\n"
        )
        print(f"    {_green('✅')} 创建 CLAUDE.md（含审计规范）")

    elif not env["claude_md_has_audit"]:
        should_append = auto or ask_yn("将在 CLAUDE.md 末尾追加审计规范，确认?", True)
        if should_append:
            with open(claude_md, "a", encoding="utf-8") as f:
                f.write(f"\n\n---\n\n{audit_section}\n")
            print(f"    {_green('✅')} 审计规范已追加到 CLAUDE.md")
        else:
            print(f"    ⏭️  跳过")

    else:
        print(f"    {_green('✅')} CLAUDE.md 已包含审计规范（跳过）")


# ==========================================
# Step 6: 验证安装
# ==========================================
def step6_verify(project: Path):
    print()
    print(_bold("--- Step 6: 验证安装 ---"))
    print()

    checks_passed = 0
    checks_total = 0

    # 6.1 audit_context.py 导入
    checks_total += 1
    try:
        sys.path.insert(0, str(project))
        # 清理可能残留的旧模块
        for mod_name in list(sys.modules.keys()):
            if mod_name in ("audit_context", "audit_config"):
                del sys.modules[mod_name]

        import audit_context as ac
        print(f"    {_green('✅')} audit_context.py 导入成功")
        checks_passed += 1
    except Exception as e:
        print(f"    {_red('❌')} audit_context.py 导入失败: {e}")

    # 6.2 audit_config.py 加载
    checks_total += 1
    try:
        import audit_config as cfg
        n_scripts = len(cfg.CORE_SCRIPTS)
        n_rules = len(cfg.ALERT_RULES)
        print(f"    {_green('✅')} audit_config.py 加载成功 (CORE_SCRIPTS: {n_scripts}, ALERT_RULES: {n_rules})")
        checks_passed += 1
    except Exception as e:
        print(f"    {_red('❌')} audit_config.py 加载失败: {e}")

    # 6.3 环境快照
    checks_total += 1
    try:
        ctx = ac.create_adhoc_context("安装验证")
        ctx.snapshot_environment()
        pt = ctx.environment.get("prompt_template")
        print(f"    {_green('✅')} 环境快照成功 (prompt_template: {pt or 'N/A'})")
        checks_passed += 1
    except Exception as e:
        print(f"    {_red('❌')} 环境快照失败: {e}")

    # 6.4 runs/ 写入
    checks_total += 1
    try:
        manifest = ctx.finalize()
        saved = ctx.save()
        print(f"    {_green('✅')} runs/ 写入成功")
        checks_passed += 1
        # 清理验证数据
        shutil.rmtree(saved)
        # 清理 index.json 中的验证条目
        idx_path = project / "runs" / "index.json"
        if idx_path.exists():
            with open(idx_path) as f:
                idx = json.load(f)
            idx["entries"] = [e for e in idx.get("entries", []) if "安装验证" not in e.get("skill", "")]
            if idx["entries"]:
                with open(idx_path, "w") as f:
                    json.dump(idx, f, ensure_ascii=False, indent=2)
            else:
                idx_path.unlink()
        print(f"    {_green('✅')} 验证数据已清理")
    except Exception as e:
        print(f"    {_red('❌')} runs/ 写入失败: {e}")

    # 6.5 Skills 存在
    checks_total += 1
    skills_dir = project / ".claude" / "skills"
    skill_count = sum(1 for d in skills_dir.iterdir() if d.is_dir() and (d / "SKILL.md").exists()) if skills_dir.exists() else 0
    if skill_count >= 4:
        print(f"    {_green('✅')} Skills 已安装 ({skill_count} 个)")
        checks_passed += 1
    else:
        print(f"    {_red('❌')} Skills 不完整 ({skill_count}/4)")

    print(f"\n    验证结果: {checks_passed}/{checks_total} 通过")
    return checks_passed == checks_total


# ==========================================
# Step 7: 安装总结
# ==========================================
def step7_summary(project: Path, all_passed: bool):
    print()
    print(_bold("=" * 60))
    if all_passed:
        print(_green(_bold("  audit-harness 安装完成！")))
    else:
        print(_yellow(_bold("  audit-harness 安装完成（部分验证未通过）")))
    print(_bold("=" * 60))
    print()
    print("  已安装组件:")
    print(f"    📦 audit_context.py    — 审计引擎")
    print(f"    ⚙️  audit_config.py     — 项目配置")
    print(f"    📂 runs/               — 审计数据存储")
    print(f"    📝 CLAUDE.md           — 审计规范")
    print()
    print("  可用 Skills:")
    print(f"    /start \"任务描述\"      — 创建审计会话 + 恢复历史上下文")
    print(f"    /end                   — 结束会话 + 审计完整性检查")
    print(f"    /recover               — 恢复丢失的 Context")
    print(f"    /report-daily          — 生成审计驱动的工作日报")
    print()
    print("  现在可以开始使用:")
    print(f"    /start \"你的第一个任务\"")
    print()
    print(_bold("=" * 60))


# ==========================================
# Main
# ==========================================
def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--auto":
        # 非交互模式：自动扫描、使用默认配置、全部安装
        project = Path(sys.argv[2]).resolve() if len(sys.argv) > 2 else Path.cwd()
        if not project.is_dir():
            print(f"错误: {project} 不是有效目录")
            sys.exit(1)

        env = step1_detect(project)

        # 自动收集配置
        py_files = scan_py_files(project)
        config = {
            "core_scripts": py_files,
            "core_assets": [str(p.name) for p in project.glob("*.pkl")] + [str(p.name) for p in project.glob("*.yaml")],
            "prompt_glob": "",
            "alert_choice": "1",
        }
        # 检查常见 prompt 模式
        for pattern in ["prompts/*.txt", "docs/prompt_*.md", "docs/long_text_*.txt"]:
            if list(project.glob(pattern)):
                config["prompt_glob"] = pattern
                break

        step3_install_core(project, config, env)
        step4_install_skills(project, env)
        step5_inject_claude_md(project, env, auto=True)
        all_passed = step6_verify(project)
        step7_summary(project, all_passed)
        return

    # 交互模式
    if len(sys.argv) > 1:
        project = Path(sys.argv[1]).resolve()
    else:
        project = Path.cwd()

    if not project.is_dir():
        print(f"错误: {project} 不是有效目录")
        sys.exit(1)

    env = step1_detect(project)

    if not ask_yn("\n  开始安装?", True):
        print("  已取消。")
        return

    config = step2_collect(project)
    step3_install_core(project, config, env)
    step4_install_skills(project, env)
    step5_inject_claude_md(project, env)
    all_passed = step6_verify(project)
    step7_summary(project, all_passed)


if __name__ == "__main__":
    main()
