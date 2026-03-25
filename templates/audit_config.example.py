"""
audit_config.py — 项目专属审计配置
===================================
将此文件复制到项目根目录并重命名为 audit_config.py。
根据你的项目修改以下配置。

audit_context.py 会自动加载此文件。
"""

# 关键脚本列表——环境快照时计算这些文件的 SHA256 哈希。
# 当这些文件被修改时，manifest 中的哈希会变化，便于追踪配置漂移。
CORE_SCRIPTS = [
    # "main.py",
    # "pipeline.py",
    # "rules.py",
]

# 关键模型/配置文件——同上
CORE_ASSETS = [
    # "model.pkl",
    # "config.yaml",
]

# Prompt 模板的 glob 模式（如果项目使用 AI prompt）
PROMPT_TEMPLATE_GLOB = ""  # 例: "prompts/*.txt" 或 "docs/prompt_*.md"

# 告警规则
# 每条规则包含: id, condition (接收 manifest dict 的 lambda), level, message
# level: "CRITICAL" (阻断) 或 "WARNING" (告警)
def _safe_div(a, b):
    return a / b if b else 0

ALERT_RULES = [
    # 示例：数据完整性校验
    # {
    #     "id": "output_integrity",
    #     "condition": lambda m: (
    #         m.get("output", {}).get("total_records") is not None
    #         and m.get("input", {}).get("total_input") is not None
    #         and m["output"]["total_records"] != m["input"]["total_input"]
    #     ),
    #     "level": "CRITICAL",
    #     "message": "输出记录数与输入不一致",
    # },

    # 示例：错误率告警
    # {
    #     "id": "error_rate",
    #     "condition": lambda m: m.get("metrics", {}).get("error_rate", 0) > 0.05,
    #     "level": "WARNING",
    #     "message": "错误率超过 5%",
    # },
]
