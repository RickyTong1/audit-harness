#!/usr/bin/env python3
# ============================================================
# L3 | lib/engram/reembed.py — 修复缺失的 embedding
#
# 用途：检测并修复那些因 MCP 进程提前退出而未完成 embedding 的记忆。
#       直接调用 Ollama /api/embed，向量结果通过 engram MCP 间接写入。
#
# 工作原理：
#   1. 从 SQLite 找到没有 embedding 的记忆
#   2. 调用 Ollama embedding API 生成向量
#   3. 通过 engram MCP 的 remember 工具触发（利用其内部 vec0 写入能力）
#      ——但不创建重复记忆，而是利用 engram 对相同 content 的幂等性
#   4. 实际采用：Node.js 直接调用 vault.computeAndStoreEmbedding
#
# 用法：
#   python3 lib/engram/reembed.py
#   python3 lib/engram/reembed.py --dry-run
#   python3 lib/engram/reembed.py --limit 10
#
# 关联文件：
#   上游：lib/engram/client.py（MCP 客户端）
#   外部：Ollama (localhost:11434), ~/.engram/default.db
# ============================================================

import sys
import os
import json
import time
import sqlite3
import urllib.request
import subprocess
import argparse

OLLAMA_BASE = os.environ.get('OLLAMA_URL', 'http://localhost:11434')
ENGRAM_DB = os.path.expanduser('~/.engram/default.db')

# engram 配置（从环境变量读取，与 mcp.js 一致）
ENGRAM_OLLAMA_MODEL = os.environ.get('ENGRAM_OLLAMA_MODEL', 'qwen3-embedding:4b')
ENGRAM_OLLAMA_DIMS = int(os.environ.get('ENGRAM_OLLAMA_DIMS', '2560'))


def find_unembedded(limit=None):
    """找到没有 embedding 的活跃记忆。"""
    conn = sqlite3.connect(ENGRAM_DB)
    conn.row_factory = sqlite3.Row

    # 有 embedding 的 memory_id 列表
    embedded = set()
    try:
        rows = conn.execute(
            "SELECT memory_id FROM vec_memories"
        ).fetchall()
        embedded = {r['memory_id'] for r in rows}
    except Exception:
        pass

    # 所有活跃记忆
    all_active = conn.execute("""
        SELECT id, content, type, salience
        FROM memories
        WHERE status = 'active'
        ORDER BY created_at DESC
    """).fetchall()

    unembedded = [m for m in all_active if m['id'] not in embedded]

    if limit:
        unembedded = unembedded[:limit]

    conn.close()
    return unembedded


def generate_embedding_ollama(text):
    """直接调用 Ollama 生成 embedding。"""
    url = f"{OLLAMA_BASE}/api/embed"
    body = json.dumps({
        'model': ENGRAM_OLLAMA_MODEL,
        'input': text,
    }).encode('utf-8')

    req = urllib.request.Request(url, data=body, headers={
        'Content-Type': 'application/json',
    })

    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.loads(resp.read())
            emb = data['embeddings'][0]
            if len(emb) > ENGRAM_OLLAMA_DIMS:
                emb = emb[:ENGRAM_OLLAMA_DIMS]
            return emb
    except Exception as e:
        print(f"  [⚠️ Ollama embedding 失败: {e}]")
        return None


def store_embedding_via_node(memory_id, embedding):
    """通过 engram 的 Node.js vault 直接写入 vec0 表。

    使用 node -e 加载 engram-sdk，调用内部方法写入向量。
    这比通过 MCP 更直接——我们不用创建重复记忆。
    """
    emb_json = json.dumps(embedding)
    script = f"""
const path = require('path');
const {{ Vault }} = require('engram-sdk/dist/vault.js');

(async () => {{
    const vault = new Vault({{
        owner: 'default',
        dbPath: '{ENGRAM_DB}',
    }});

    // 直接用 vault 的内部 store 写入向量
    // vec0 插入语法
    const db = vault.store.db;
    const emb = {emb_json};
    const buffer = Buffer.from(new Float32Array(emb).buffer);

    try {{
        db.run(
            "INSERT OR REPLACE INTO vec_memories (memory_id, embedding) VALUES (?, ?)",
            ['{memory_id}', buffer]
        );
        // 同步 rowids 表
        const row = db.prepare(
            "SELECT rowid FROM vec_memories WHERE memory_id = ?"
        ).get('{memory_id}');
        console.log('OK');
    }} catch (e) {{
        console.error('FAIL: ' + e.message);
    }}
}})();
"""
    try:
        result = subprocess.run(
            ['node', '-e', script],
            capture_output=True, text=True, timeout=15,
            cwd=os.path.expanduser('~')
        )
        return 'OK' in result.stdout
    except Exception as e:
        print(f"  [⚠️ Node 写入失败: {e}]")
        return False


def main():
    parser = argparse.ArgumentParser(
        description='修复 engram 缺失的 embedding'
    )
    parser.add_argument('--dry-run', action='store_true',
                        help='只检测不修复')
    parser.add_argument('--limit', type=int, default=None,
                        help='最多修复 N 条（默认全部）')
    parser.add_argument('--json', action='store_true',
                        help='JSON 格式输出')

    args = parser.parse_args()

    # Step 1: 检测
    unembedded = find_unembedded(limit=args.limit)

    if not args.json:
        print(f"🔍 缺失 embedding 的记忆: {len(unembedded)} 条")
        if not unembedded:
            print("   ✅ 全部记忆都有 embedding！")
            return

    if args.dry_run:
        if not args.json:
            print(f"\n--- Dry Run 预览（前10条）---")
            for m in unembedded[:10]:
                print(f"  [{m['type']}] {m['content'][:80]}...")
        if args.json:
            print(json.dumps({
                'missing': len(unembedded),
                'dry_run': True,
                'samples': [m['content'][:80] for m in unembedded[:5]],
            }, ensure_ascii=False))
        return

    # Step 2: 修复
    success = 0
    fail = 0

    for i, m in enumerate(unembedded):
        if not args.json:
            print(f"  [{i+1}/{len(unembedded)}] {m['content'][:60]}...", end=' ')

        # 生成 embedding
        emb = generate_embedding_ollama(m['content'])
        if not emb:
            fail += 1
            if not args.json:
                print("❌ (Ollama)")
            continue

        # 写入 vec0
        if store_embedding_via_node(m['id'], emb):
            success += 1
            if not args.json:
                print("✅")
        else:
            fail += 1
            if not args.json:
                print("❌ (写入)")

    if not args.json:
        print(f"\n📊 修复完成: {success} 成功, {fail} 失败")
    else:
        print(json.dumps({
            'missing': len(unembedded),
            'fixed': success,
            'failed': fail,
        }, ensure_ascii=False))


if __name__ == '__main__':
    main()
