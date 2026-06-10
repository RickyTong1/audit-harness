#!/usr/bin/env python3
# ============================================================
# L3 | lib/engram/consolidate_llm.py — 本地 LLM 语义提炼
#
# 用途：用本地 Ollama 模型（llama3.1/qwen3）替代 Gemini API，
#       对 episodic 记忆做语义提炼，产出 semantic 记忆 + 图谱关联。
#
# 输入：engram vault 中最近 24h 的 episodic 记忆
# 输出：新创建的 semantic 记忆 + derived_from 边
#
# 设计：
#   1. 通过 MCP recall 获取最近 episodic 记忆
#   2. 按实体重叠分组（复用 rule-based consolidate 的 edges）
#   3. 每组发送到 Ollama 做语义提炼
#   4. 提炼结果通过 MCP 写入 semantic 记忆
#   5. 建立 episodic → semantic 的 derived_from 边
#
# 用法：
#   python3 lib/engram/consolidate_llm.py
#   python3 lib/engram/consolidate_llm.py --model qwen3:4b --dry-run
#
# 关联文件：
#   上游：docs/L2_engram_memory_integration.md §7（Consolidation 设计）
#   内部：lib/engram/client.py（MCP 客户端）
#   外部：Ollama (localhost:11434)
# ============================================================

import sys
import json
import time
import argparse
import urllib.request
import urllib.error

# 添加父目录到路径以导入 client
import os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from client import EngramClient


# ============================================================
# 配置
# ============================================================

OLLAMA_BASE = os.environ.get('OLLAMA_URL', 'http://localhost:11434')
DEFAULT_MODEL = 'qwen3:8b'  # 本地 reasoning 模型，中文原生支持
MAX_EPISODES_PER_GROUP = 10
MIN_SALIENCE = 0.3


# ============================================================
# Ollama Chat API
# ============================================================

def ollama_chat(model, system_prompt, user_prompt, temperature=0.3):
    """调用 Ollama OpenAI 兼容 API 做 chat completion。

    qwen3:8b 是 reasoning 模型（会先内部推理再输出），
    需要更大的 max_tokens 容纳推理过程 + 最终输出。
    """
    url = f"{OLLAMA_BASE}/v1/chat/completions"
    body = json.dumps({
        'model': model,
        'messages': [
            {'role': 'system', 'content': system_prompt},
            {'role': 'user', 'content': user_prompt},
        ],
        'temperature': temperature,
        'max_tokens': 4096,  # reasoning 模型需要足够空间（推理+输出）
    }).encode('utf-8')

    req = urllib.request.Request(url, data=body, headers={
        'Content-Type': 'application/json',
    })

    try:
        with urllib.request.urlopen(req, timeout=180) as resp:
            data = json.loads(resp.read())
            msg = data['choices'][0]['message']
            # reasoning 模型：优先取 content，为空则尝试从 reasoning 提取
            content = msg.get('content', '')
            if not content:
                # 推理模型的输出可能在 reasoning 字段中
                reasoning = msg.get('reasoning', '')
                # 从 reasoning 尾部提取 JSON（最终答案通常在末尾）
                content = reasoning
            return content
    except Exception as e:
        print(f"  [⚠️ Ollama 调用失败: {e}]", file=sys.stderr)
        return None


# ============================================================
# Consolidation 核心逻辑
# ============================================================

CONSOLIDATION_SYSTEM_PROMPT = """You are a memory consolidation engine. Your job is to read a set of related episodic memories and extract structured, reusable knowledge from them.

For each insight you extract, provide:
- content: A clear, standalone statement that captures the reusable knowledge (make sense without original context)
- topics: Topic tags as an array (e.g., ["bug", "fix", "LoRA", "nan_loss"])
- salience: Importance 0.0-1.0 based on how often this pattern recurs and its impact
- confidence: 0.0-1.0 based on how clearly the episodes support this conclusion
- supersedes: (optional) If this replaces an older conclusion, describe what it replaces

Rules:
1. Extract ONLY reusable knowledge — not one-off events
2. Be concise but complete — each statement should be self-contained
3. Merge related observations into single insights (don't create one-per-episode)
4. For bug fixes: capture ROOT CAUSE → FIX → VERIFICATION chain
5. Skip trivial content (tool invocations, file paths, acknowledgments)

Return JSON:
{
  "insights": [
    {
      "content": "...reusable knowledge statement...",
      "topics": ["tag1", "tag2"],
      "salience": 0.7,
      "confidence": 0.8,
      "supersedes": null
    }
  ],
  "summary": "One sentence summarizing what was learned"
}"""


def group_episodes_by_entity(episodes):
    """按实体重叠将 episodes 分组。

    使用简单的 entity overlap 聚类：两个 episode 共享至少一个实体 → 同组。
    """
    if not episodes:
        return []

    # 提取每个 episode 的实体集合
    ep_entities = []
    for ep in episodes:
        entities = set(ep.get('entities', []))
        ep_entities.append(entities)

    # Union-Find 聚类
    parent = list(range(len(episodes)))

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    def union(x, y):
        px, py = find(x), find(y)
        if px != py:
            parent[px] = py

    for i in range(len(episodes)):
        for j in range(i + 1, len(episodes)):
            if ep_entities[i] & ep_entities[j]:  # 共享实体
                union(i, j)

    # 收集分组
    groups = {}
    for i in range(len(episodes)):
        root = find(i)
        if root not in groups:
            groups[root] = []
        # 截取内容前 300 字符避免 token 爆炸
        content = episodes[i].get('content', '')[:300]
        groups[root].append(content)

    return list(groups.values())


def consolidate_with_ollama(client, model=DEFAULT_MODEL, dry_run=False):
    """用本地 Ollama 模型执行语义提炼。

    Args:
        client: EngramClient 实例
        model: Ollama 模型名
        dry_run: True 时只预览不写入

    Returns:
        统计报告 dict
    """
    print(f"🧠 本地 LLM Consolidation")
    print(f"   模型: {model}")
    print(f"   Ollama: {OLLAMA_BASE}")
    print()

    # Step 1: 获取最近 24h 的高质量 episodic 记忆
    print("📥 Step 1: 获取最近 episodic 记忆...")
    recall_result = client.recall(
        context="bug fix error solution conclusion preference change",
        limit=30,
        memory_type='episodic',
    )

    if not recall_result:
        print("   (无 episodic 记忆或 MCP 不可用)")
        return {'episodes': 0, 'groups': 0, 'insights': 0, 'dry_run': dry_run}

    # 从 recall 文本中解析记忆（engram recall 返回格式化文本）
    # 我们直接用 MCP 获取 raw data 更可靠
    # 替代方案：通过 SQLite 直接读取（只读，不做修改）
    import sqlite3
    db_path = os.path.expanduser('~/.engram/default.db')
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row

    one_day_ago = time.strftime(
        '%Y-%m-%dT%H:%M:%SZ',
        time.gmtime(time.time() - 24 * 3600)
    )

    episodes = conn.execute("""
        SELECT id, content, entities, topics, salience, created_at
        FROM memories
        WHERE type = 'episodic'
          AND status = 'active'
          AND salience >= ?
          AND created_at >= ?
        ORDER BY salience DESC
        LIMIT 30
    """, (MIN_SALIENCE, one_day_ago)).fetchall()

    conn.close()

    if not episodes:
        print("   没有找到符合条件的 episodic 记忆")
        return {'episodes': 0, 'groups': 0, 'insights': 0, 'dry_run': dry_run}

    print(f"   找到 {len(episodes)} 条 episodic 记忆 (salience ≥ {MIN_SALIENCE})")

    # Step 2: 按实体分组
    print("\n📦 Step 2: 按实体重叠分组...")
    ep_dicts = []
    for ep in episodes:
        ep_dicts.append({
            'id': ep['id'],
            'content': ep['content'],
            'entities': json.loads(ep['entities']) if ep['entities'] else [],
            'topics': json.loads(ep['topics']) if ep['topics'] else [],
            'salience': ep['salience'],
        })

    groups = group_episodes_by_entity(ep_dicts)
    print(f"   分成 {len(groups)} 组")

    # 过滤：只处理有 ≥2 条记忆的组（单独一条不足以提炼）
    qualified_groups = [(i, g) for i, g in enumerate(groups) if len(g) >= 2]
    print(f"   其中 {len(qualified_groups)} 组有 ≥2 条相关记忆（可提炼）")

    if not qualified_groups:
        print("   (没有足够的密集 episode 组，跳过 LLM 提炼)")
        return {'episodes': len(episodes), 'groups': len(groups),
                'insights': 0, 'dry_run': dry_run}

    # Step 3: 对每组做 LLM 提炼
    print(f"\n🤖 Step 3: Ollama 语义提炼...")
    total_insights = 0

    for group_idx, group in qualified_groups:
        # 限制每组最多 MAX_EPISODES_PER_GROUP 条记忆
        group = group[:MAX_EPISODES_PER_GROUP]

        # 构建 prompt
        episodes_text = "\n\n".join(
            f"[{i+1}] {content}"
            for i, content in enumerate(group)
        )

        print(f"   组 {group_idx+1}/{len(qualified_groups)} ({len(group)} 条记忆)...", end=' ')

        response = ollama_chat(
            model=model,
            system_prompt=CONSOLIDATION_SYSTEM_PROMPT,
            user_prompt=f"Extract reusable knowledge from these related episodes:\n\n{episodes_text}",
        )

        if not response:
            print("失败")
            continue

        # 解析响应
        try:
            result = json.loads(response)
            insights = result.get('insights', [])
            summary = result.get('summary', '')
        except json.JSONDecodeError:
            # 尝试从 markdown 代码块中提取
            import re
            match = re.search(r'```json\s*([\s\S]*?)\s*```', response)
            if match:
                try:
                    result = json.loads(match.group(1))
                    insights = result.get('insights', [])
                    summary = result.get('summary', '')
                except json.JSONDecodeError:
                    print(f"JSON 解析失败")
                    continue
            else:
                print(f"JSON 解析失败")
                continue

        print(f"→ {len(insights)} 条 insight")

        # Step 4: 写入 semantic 记忆 + 建立 derived_from 边
        for insight in insights:
            content = insight.get('content', '')
            if not content or len(content) < 20:
                continue

            topics = insight.get('topics', [])
            topics.append('consolidated')  # 标记来源

            salience = insight.get('salience', 0.5)
            confidence = insight.get('confidence', 0.7)

            if dry_run:
                print(f"      [DRY-RUN] 将写入: {content[:80]}...")
                print(f"               topics={topics}, salience={salience}")
                total_insights += 1
            else:
                # 通过 MCP 写入
                result_text = client.remember(
                    content=content,
                    memory_type='semantic',
                    topics=topics,
                    salience=salience,
                )
                if result_text:
                    total_insights += 1
                    # 尝试提取 memory ID 建立 derived_from 边
                    # （engram remember 响应格式: "✓ Remembered: ...\n  ID: xxx | Type: ..."）
                    import re as re_mod
                    id_match = re_mod.search(r'ID: ([a-f0-9-]+)', result_text)
                    if id_match:
                        semantic_id = id_match.group(1)
                        # 为组内每条 episode 建立 derived_from 边
                        # （通过 SQLite 直接写 edges，因为连接逻辑简单）
                        conn2 = sqlite3.connect(db_path)
                        for ep in group:
                            ep_id = ep_dicts[0]['id'] if isinstance(ep, str) else ''
                            # 从原始 episodes 中找到对应的 id
                            for orig_ep in ep_dicts:
                                if orig_ep['content'][:50] in (ep[:50] if isinstance(ep, str) else ''):
                                    conn2.execute(
                                        "INSERT OR IGNORE INTO edges (id, source_id, target_id, type, strength, created_at) VALUES (?, ?, ?, 'derived_from', 0.7, ?)",
                                        (f"edge_{semantic_id}_{orig_ep['id']}",
                                         semantic_id, orig_ep['id'],
                                         time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()))
                                    )
                            break  # 目前只连第一条(简化实现)
                        conn2.commit()
                        conn2.close()

    # 清理 consolidation meta-noise（engram 自动存的 procedural）
    if not dry_run:
        conn3 = sqlite3.connect(db_path)
        deleted = conn3.execute(
            "DELETE FROM memories WHERE type='procedural' AND content LIKE 'Consolidation completed%'"
        ).rowcount
        if deleted:
            conn3.execute(
                "DELETE FROM edges WHERE source_id IN (SELECT id FROM memories WHERE type='procedural' AND content LIKE 'Consolidation completed%')"
            )
        conn3.commit()
        conn3.close()
        if deleted:
            print(f"\n🧹 清理 {deleted} 条 consolidation meta-noise")

    report = {
        'episodes': len(episodes),
        'groups': len(groups),
        'qualified_groups': len(qualified_groups),
        'insights': total_insights,
        'model': model,
        'dry_run': dry_run,
    }

    print(f"\n✅ 完成: {total_insights} 条 semantic insight 从 "
          f"{len(episodes)} 条 episode ({len(qualified_groups)} 组) 中提炼")

    return report


# ============================================================
# CLI 入口
# ============================================================

def main():
    parser = argparse.ArgumentParser(
        description='本地 LLM 语义提炼 — 用 Ollama 模型从 episodic 记忆提炼 semantic 知识'
    )
    parser.add_argument('--model', default=DEFAULT_MODEL,
                        help=f'Ollama 模型名 (默认: {DEFAULT_MODEL})')
    parser.add_argument('--dry-run', action='store_true',
                        help='预览模式，不实际写入')
    parser.add_argument('--json', action='store_true',
                        help='JSON 格式输出')

    args = parser.parse_args()

    client = EngramClient()
    try:
        report = consolidate_with_ollama(client, model=args.model, dry_run=args.dry_run)
    finally:
        client.close()

    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
    elif report['insights'] == 0 and not args.dry_run:
        print("\n💡 提示：")
        print("   - 当前可能没有足够密集的 episodic 记忆（需要 ≥2 条共享实体的记忆）")
        print("   - 先通过 /audit-end 灌入更多 session 数据")
        print("   - 或用 --dry-run 预览哪些记忆会被分组")


if __name__ == '__main__':
    main()
