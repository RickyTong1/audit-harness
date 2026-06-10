#!/usr/bin/env python3
# ============================================================
# L3 | lib/engram/client.py — engram MCP 结构化客户端
#
# 用途：通过 MCP JSON-RPC 协议与 engram MCP server 通信，
#       提供完整的结构化记忆操作（type, topics, salience, entities）。
#       不操作 SQLite，不嵌入 engram 内部逻辑。
#
# 输入：命令行子命令 + JSON 参数（stdin）
# 输出：JSON 结果（stdout），错误静默（exit 0）
#
# 关联文件：
#   上游：docs/L1_memory_architecture.md（双层记忆蓝图）
#         docs/L2_engram_memory_integration.md（集成设计）
#   下游：lib/engram/wrapper.sh（bash 封装）
#         skills/audit-end/SKILL.md §7（写入管道）
#         skills/audit-start/SKILL.md §2a（双源恢复）
#         skills/audit-recover/SKILL.md（双源恢复）
#   外部：~/.engram/default.db（engram vault，不直接访问）
#         engram mcp（子进程，JSON-RPC over stdio）
# ============================================================

import sys
import json
import subprocess
import os
import time
import atexit

# ============================================================
# EngramClient — 管理 MCP 子进程，暴露所有 engram 操作
# ============================================================

class EngramClient:
    """通过 MCP JSON-RPC 与 engram mcp server 通信的客户端。"""

    def __init__(self):
        self._proc = None
        self._request_id = 0
        self._initialized = False

    def _ensure_started(self):
        """启动 engram mcp 子进程并完成 MCP 握手。"""
        if self._proc is not None:
            return True

        try:
            env = os.environ.copy()
            # 继承 engram 环境变量（OLLAMA_MODEL, GEMINI_API_KEY 等）
            self._proc = subprocess.Popen(
                ['engram', 'mcp'],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,  # 静默 auto-ingest 等噪音
                text=True,
                env=env,
            )

            # MCP 握手：initialize
            init_resp = self._send_request('initialize', {
                'protocolVersion': '2024-11-05',
                'capabilities': {},
                'clientInfo': {'name': 'audit-harness', 'version': '4.0.0'}
            })
            if init_resp is None:
                self._cleanup()
                return False

            # MCP 握手：initialized 通知（不需要响应）
            self._send_notification('notifications/initialized', {})

            self._initialized = True
            return True

        except Exception:
            self._cleanup()
            return False

    def _send_request(self, method, params):
        """发送 JSON-RPC 请求，返回 result 或 None。

        engram mcp 启动时会通过 stdout 输出 auto-ingest 进度信息
        （非 JSON），需要跳过这些行，只解析合法的 JSON-RPC 响应。
        """
        try:
            self._request_id += 1
            req = {
                'jsonrpc': '2.0',
                'id': self._request_id,
                'method': method,
                'params': params,
            }
            self._proc.stdin.write(json.dumps(req, ensure_ascii=False) + '\n')
            self._proc.stdin.flush()

            # 循环读取行，跳过非 JSON 行，匹配响应 ID
            deadline = time.time() + 30  # 30 秒超时
            while time.time() < deadline:
                line = self._proc.stdout.readline()
                if not line:
                    time.sleep(0.05)
                    continue

                line = line.strip()
                if not line:
                    continue

                # 尝试解析为 JSON
                try:
                    resp = json.loads(line)
                except json.JSONDecodeError:
                    # auto-ingest 日志或其他非 JSON 输出，跳过
                    continue

                # 检查是否匹配我们的请求 ID
                if resp.get('id') != self._request_id:
                    # 可能是通知或其他请求的响应，跳过
                    continue

                if 'error' in resp:
                    return None
                return resp.get('result', None)

            # 超时
            return None

        except Exception:
            return None

    def _send_notification(self, method, params):
        """发送 JSON-RPC 通知（无 id，不期待响应）。"""
        try:
            notif = {
                'jsonrpc': '2.0',
                'method': method,
                'params': params,
            }
            self._proc.stdin.write(json.dumps(notif, ensure_ascii=False) + '\n')
            self._proc.stdin.flush()
        except Exception:
            pass

    def _call_tool(self, tool_name, arguments):
        """调用 MCP 工具，返回 text 内容或 None。"""
        if not self._ensure_started():
            return None

        result = self._send_request('tools/call', {
            'name': tool_name,
            'arguments': arguments,
        })
        if result is None:
            return None

        # MCP 工具返回格式：{ content: [{ type: 'text', text: '...' }] }
        try:
            content = result.get('content', [])
            if content and len(content) > 0:
                return content[0].get('text', str(result))
            return str(result)
        except Exception:
            return str(result) if result else None

    def _cleanup(self):
        """清理子进程。"""
        if self._proc:
            try:
                self._proc.stdin.close()
                self._proc.stdout.close()
                self._proc.terminate()
                self._proc.wait(timeout=2)
            except Exception:
                try:
                    self._proc.kill()
                except Exception:
                    pass
            self._proc = None
            self._initialized = False

    def close(self):
        self._cleanup()

    # ============================================================
    # 公开 API — 每个方法对应一个 engram MCP 工具
    # ============================================================

    def remember(self, content, memory_type=None, topics=None,
                 entities=None, salience=None, status=None):
        """结构化写入记忆。

        Args:
            content: 记忆文本内容
            memory_type: 'episodic' | 'semantic' | 'procedural'
            topics: 话题标签列表，如 ['project:audit-harness', 'correction']
            entities: 实体列表，如 ['Ricky Tong', 'LoRA']
            salience: 重要性 0.0-1.0
            status: 'active' | 'pending' | 'fulfilled' | 'superseded' | 'archived'

        Returns:
            结果文本 或 None
        """
        args = {'content': content}
        if memory_type:
            args['type'] = memory_type
        if topics:
            args['topics'] = topics
        if entities:
            args['entities'] = entities
        if salience is not None:
            args['salience'] = salience
        if status:
            args['status'] = status

        result = self._call_tool('engram_remember', args)
        # 等待异步 embedding 完成——engram 在 remember 返回后
        # 异步调用 computeAndStoreEmbedding，需给 Ollama 时间生成向量
        if self._proc is not None:
            import time as _time
            _time.sleep(1.5)
        return result

    def recall(self, context, topics=None, entities=None,
               limit=10, memory_type=None):
        """语义召回记忆。

        Args:
            context: 查询上下文/问题
            topics: 按话题过滤（MCP 软过滤，排名提升）
            entities: 按实体过滤
            limit: 最大返回数（默认 10，最大 50）
            memory_type: 按类型过滤

        Returns:
            格式化文本 或 None
        """
        args = {'context': context, 'limit': limit}
        if topics:
            args['topics'] = topics
        if entities:
            args['entities'] = entities
        if memory_type:
            args['type'] = memory_type

        return self._call_tool('engram_recall', args)

    def consolidate(self):
        """运行记忆整理——提炼语义知识、发现实体、形成关联。

        Returns:
            JSON 格式的整理报告文本 或 None
        """
        return self._call_tool('engram_consolidate', {})

    def forget(self, memory_id, hard=False):
        """删除记忆。

        Args:
            memory_id: 记忆 ID
            hard: True=物理删除, False=软删除(salience→0)

        Returns:
            结果文本 或 None
        """
        return self._call_tool('engram_forget', {
            'id': memory_id,
            'hard': hard,
        })

    def connect(self, source_id, target_id, rel_type, strength=None):
        """建立记忆间关系。

        Args:
            source_id: 源记忆 ID
            target_id: 目标记忆 ID
            rel_type: 关系类型 (supports|contradicts|elaborates|supersedes|
                     causes|caused_by|part_of|instance_of|
                     associated_with|temporal_next|derived_from)
            strength: 关联强度 0.0-1.0

        Returns:
            结果文本 或 None
        """
        args = {
            'sourceId': source_id,
            'targetId': target_id,
            'type': rel_type,
        }
        if strength is not None:
            args['strength'] = strength
        return self._call_tool('engram_connect', args)

    def alerts(self, stale_days=3, limit=5):
        """获取待处理告警。

        Args:
            stale_days: 超过多少天未访问算 stale
            limit: 最大返回数

        Returns:
            告警文本 或 None
        """
        return self._call_tool('engram_alerts', {
            'staleDays': stale_days,
            'limit': limit,
        })

    def surface(self, context=None, active_entities=None, active_topics=None):
        """主动推送相关记忆。

        Args:
            context: 当前任务描述
            active_entities: 当前活跃实体列表
            active_topics: 当前活跃话题列表

        Returns:
            推送文本 或 None
        """
        args = {}
        if context:
            args['context'] = context
        if active_entities:
            args['activeEntities'] = active_entities
        if active_topics:
            args['activeTopics'] = active_topics
        return self._call_tool('engram_surface', args)

    def briefing(self, context=None, project=None):
        """获取会话简报。

        Args:
            context: 任务描述
            project: 项目名

        Returns:
            简报文本 或 None
        """
        args = {}
        if context:
            args['context'] = context
        if project:
            args['project'] = project
        return self._call_tool('engram_briefing', args)

    def stats(self):
        """获取 vault 统计信息。

        Returns:
            统计文本 或 None
        """
        return self._call_tool('engram_stats', {})

    def experience(self, context, topics=None, limit=5,
                   graph_hops=1, forgetting_lambda=0.05):
        """经验图谱检索——语义召回 + 图谱遍历 + 遗忘衰减。

        专为 bugfix / problem-solving / planning 场景设计。
        不仅返回语义匹配的记忆，还沿知识图谱边追溯到相关经验。

        Args:
            context: 问题描述
            topics: 话题过滤
            limit: 语义召回数量
            graph_hops: 图谱跳数（1=直接邻居, 2=邻居的邻居）
            forgetting_lambda: 遗忘速率 λ（越大遗忘越快，默认0.05=温和遗忘）

        Returns:
            结构化经验报告 dict:
            {
              'direct_matches': [...],    # 语义召回
              'graph_neighbors': [...],    # 图谱邻居（1-hop, 2-hop）
              'causal_chains': [...],      # 因果链
              'related_fixes': [...],      # 历史修复
            }
        """
        import sqlite3
        import math
        import time as _time

        # Step 1: 语义召回
        recall_text = self.recall(
            context=context,
            topics=topics,
            limit=limit,
        )
        if not recall_text:
            return None

        # Step 2: 从 SQLite 读取记忆元数据（只读——获取 ID、salience、entities、
        #         edges 等结构化字段。不写入。）
        db_path = os.path.expanduser('~/.engram/default.db')
        conn = sqlite3.connect(db_path)
        conn.row_factory = sqlite3.Row

        # 通过 content 前80字符匹配找到语义召回的 memory IDs
        recall_lines = recall_text.split('\n')
        matched_ids = []
        for line in recall_lines:
            # 找到形如 "  ID: xxx | Type:" 的行
            if 'ID:' in line and '|' in line:
                import re
                id_match = re.search(
                    r'ID: ([a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-'
                    r'[a-f0-9]{4}-[a-f0-9]{12})', line)
                if id_match:
                    matched_ids.append(id_match.group(1))

        # 如果召回文本不含 ID（engram 默认格式），通过 content 子串匹配
        if not matched_ids:
            for i, line in enumerate(recall_lines):
                if line.startswith('[') and ']' in line[:6]:
                    # 提取紧跟着的内容行
                    if i + 1 < len(recall_lines):
                        content_line = recall_lines[i + 1]
                        if len(content_line) > 20:
                            rows = conn.execute(
                                "SELECT id FROM memories WHERE content LIKE ? LIMIT 1",
                                (content_line[:60] + '%',)
                            ).fetchall()
                            if rows:
                                matched_ids.append(rows[0]['id'])

        if not matched_ids:
            conn.close()
            return {'direct_matches': [], 'graph_neighbors': [],
                    'causal_chains': [], 'related_fixes': []}

        # Step 3: 读取匹配记忆的完整元数据
        placeholders = ','.join(['?'] * len(matched_ids))
        direct_matches = conn.execute(f"""
            SELECT id, content, type, salience, confidence,
                   entities, topics, created_at, last_accessed_at, status
            FROM memories
            WHERE id IN ({placeholders}) AND status = 'active'
            ORDER BY salience DESC
        """, matched_ids).fetchall()

        now = _time.time()

        def calc_recency_score(memory_row):
            """计算遗忘衰减分数: e^(-λ × days_since_access)"""
            try:
                accessed = memory_row['last_accessed_at'] or memory_row['created_at']
                # 解析 ISO 8601
                accessed_ts = _time.mktime(_time.strptime(
                    accessed[:19], '%Y-%m-%dT%H:%M:%S'))
                days = (now - accessed_ts) / 86400
                return math.exp(-forgetting_lambda * days)
            except Exception:
                return 1.0

        # Step 4: 图谱遍历（1-hop 邻居）
        all_neighbor_ids = set()
        graph_neighbors = []

        for match in direct_matches:
            mid = match['id']
            neighbors = conn.execute("""
                SELECT DISTINCT
                    CASE WHEN e.source_id = ? THEN e.target_id ELSE e.source_id END as neighbor_id,
                    e.type as edge_type,
                    e.strength
                FROM edges e
                WHERE (e.source_id = ? OR e.target_id = ?)
            """, (mid, mid, mid)).fetchall()

            for n in neighbors:
                nid = n['neighbor_id']
                if nid not in matched_ids and nid not in all_neighbor_ids:
                    all_neighbor_ids.add(nid)

        # 读取邻居记忆
        if all_neighbor_ids and graph_hops >= 1:
            n_placeholders = ','.join(['?'] * len(all_neighbor_ids))
            neighbor_rows = conn.execute(f"""
                SELECT id, content, type, salience, confidence,
                       entities, topics, created_at, status
                FROM memories
                WHERE id IN ({n_placeholders}) AND status = 'active'
                ORDER BY salience DESC
                LIMIT 20
            """, list(all_neighbor_ids)).fetchall()

            for nr in neighbor_rows:
                recency = calc_recency_score(nr)
                # 组合分数：salience × recency（遗忘衰减）
                combined_score = round(nr['salience'] * recency, 3)
                graph_neighbors.append({
                    'id': nr['id'],
                    'content': nr['content'][:200],
                    'type': nr['type'],
                    'salience': nr['salience'],
                    'recency': round(recency, 3),
                    'combined_score': combined_score,
                })

            # 按组合分数排序
            graph_neighbors.sort(key=lambda x: x['combined_score'], reverse=True)

        # Step 5: 识别因果链和修复
        causal_chains = []
        related_fixes = []

        all_ids = matched_ids + list(all_neighbor_ids)
        if all_ids:
            ap = ','.join(['?'] * len(all_ids))
            causal_edges = conn.execute(f"""
                SELECT e.source_id, e.target_id, e.type, e.strength,
                       m1.content as src_content, m2.content as tgt_content
                FROM edges e
                JOIN memories m1 ON e.source_id = m1.id
                JOIN memories m2 ON e.target_id = m2.id
                WHERE (e.type IN ('causes', 'caused_by', 'supersedes', 'derived_from'))
                  AND (e.source_id IN ({ap}) OR e.target_id IN ({ap}))
                ORDER BY e.strength DESC
                LIMIT 10
            """, all_ids * 2).fetchall()

            for ce in causal_edges:
                chain = {
                    'type': ce['type'],
                    'strength': ce['strength'],
                    'source': ce['src_content'][:100] if ce['src_content'] else '',
                    'target': ce['tgt_content'][:100] if ce['tgt_content'] else '',
                }
                if ce['type'] in ('causes', 'caused_by'):
                    causal_chains.append(chain)
                elif ce['type'] in ('supersedes', 'derived_from'):
                    related_fixes.append(chain)

        conn.close()

        # Step 6: 构建报告
        return {
            'direct_matches': [
                {
                    'id': m['id'],
                    'content': m['content'][:200],
                    'type': m['type'],
                    'salience': m['salience'],
                    'recency': round(calc_recency_score(m), 3),
                }
                for m in direct_matches[:limit]
            ],
            'graph_neighbors': graph_neighbors[:15],
            'causal_chains': causal_chains[:5],
            'related_fixes': related_fixes[:5],
        }

    def batch(self, operations):
        """批量执行多个操作，复用同一个 MCP 连接。

        这是解决自动化性能问题的关键——避免每次调用重启 MCP 进程。
        单个 MCP 进程启动 ~0.5s（auto-ingest + 握手），
        N 次独立调用 = N×0.5s 开销。batch 模式只需一次启动。

        Args:
            operations: 操作列表，每项 {"cmd": "remember", "args": {...}}
                       支持的命令: remember, recall, consolidate, forget,
                       connect, alerts, surface, briefing, stats

        Returns:
            结果列表 [{"cmd": "remember", "ok": true, "result": "..."}, ...]
            单个操作失败不影响其他操作。
        """
        results = []
        for op in operations:
            cmd = op.get('cmd', '')
            args = op.get('args', {})
            result = None
            ok = True

            try:
                if cmd == 'remember':
                    result = self.remember(
                        content=args.get('content', ''),
                        memory_type=args.get('type'),
                        topics=args.get('topics'),
                        entities=args.get('entities'),
                        salience=args.get('salience'),
                        status=args.get('status'),
                    )
                elif cmd == 'recall':
                    result = self.recall(
                        context=args.get('context', ''),
                        topics=args.get('topics'),
                        entities=args.get('entities'),
                        limit=args.get('limit', 10),
                        memory_type=args.get('type'),
                    )
                elif cmd == 'consolidate':
                    result = self.consolidate()
                elif cmd == 'forget':
                    result = self.forget(
                        memory_id=args.get('id', ''),
                        hard=args.get('hard', False),
                    )
                elif cmd == 'connect':
                    result = self.connect(
                        source_id=args.get('sourceId', ''),
                        target_id=args.get('targetId', ''),
                        rel_type=args.get('type', 'associated_with'),
                        strength=args.get('strength'),
                    )
                elif cmd == 'alerts':
                    result = self.alerts(
                        stale_days=args.get('staleDays', 3),
                        limit=args.get('limit', 5),
                    )
                elif cmd == 'surface':
                    result = self.surface(
                        context=args.get('context'),
                        active_entities=args.get('activeEntities'),
                        active_topics=args.get('activeTopics'),
                    )
                elif cmd == 'briefing':
                    result = self.briefing(
                        context=args.get('context'),
                        project=args.get('project'),
                    )
                elif cmd == 'stats':
                    result = self.stats()
                elif cmd == 'experience':
                    result = self.experience(
                        context=args.get('context', ''),
                        topics=args.get('topics'),
                        limit=args.get('limit', 5),
                        graph_hops=args.get('graphHops', 1),
                        forgetting_lambda=args.get('forgettingLambda', 0.05),
                    )
                else:
                    result = f'unknown command: {cmd}'
                    ok = False
            except Exception as e:
                result = str(e)
                ok = False

            results.append({
                'cmd': cmd,
                'ok': ok,
                'result': result,
            })

        return results


# ============================================================
# CLI 入口（由 wrapper.sh 调用）
# ============================================================

def _parse_json_arg(raw):
    """安全解析 JSON 参数，失败返回 None。"""
    try:
        return json.loads(raw) if raw else None
    except (json.JSONDecodeError, TypeError):
        return None


def _fail(msg):
    """输出错误并退出 0（不阻断主流程）。"""
    print(json.dumps({'ok': False, 'error': msg}, ensure_ascii=False))
    sys.exit(0)


def _ok(result):
    """输出成功结果并退出 0。"""
    output = {'ok': True}
    if result is not None:
        output['result'] = result
    print(json.dumps(output, ensure_ascii=False, default=str))
    sys.exit(0)


def main():
    if len(sys.argv) < 2:
        _fail('usage: client.py <command> [json_args]')

    command = sys.argv[1]
    raw_args = sys.argv[2] if len(sys.argv) > 2 else '{}'
    args = _parse_json_arg(raw_args) or {}

    client = EngramClient()
    # 确保进程清理
    atexit.register(client.close)

    try:
        if command == 'remember':
            result = client.remember(
                content=args.get('content', ''),
                memory_type=args.get('type'),
                topics=args.get('topics'),
                entities=args.get('entities'),
                salience=args.get('salience'),
                status=args.get('status'),
            )
            _ok(result)

        elif command == 'recall':
            result = client.recall(
                context=args.get('context', ''),
                topics=args.get('topics'),
                entities=args.get('entities'),
                limit=args.get('limit', 10),
                memory_type=args.get('type'),
            )
            _ok(result)

        elif command == 'consolidate':
            result = client.consolidate()
            _ok(result)

        elif command == 'forget':
            result = client.forget(
                memory_id=args.get('id', ''),
                hard=args.get('hard', False),
            )
            _ok(result)

        elif command == 'connect':
            result = client.connect(
                source_id=args.get('sourceId', ''),
                target_id=args.get('targetId', ''),
                rel_type=args.get('type', 'associated_with'),
                strength=args.get('strength'),
            )
            _ok(result)

        elif command == 'alerts':
            result = client.alerts(
                stale_days=args.get('staleDays', 3),
                limit=args.get('limit', 5),
            )
            _ok(result)

        elif command == 'surface':
            result = client.surface(
                context=args.get('context'),
                active_entities=args.get('activeEntities'),
                active_topics=args.get('activeTopics'),
            )
            _ok(result)

        elif command == 'briefing':
            result = client.briefing(
                context=args.get('context'),
                project=args.get('project'),
            )
            _ok(result)

        elif command == 'stats':
            result = client.stats()
            _ok(result)

        elif command == 'experience':
            result = client.experience(
                context=args.get('context', ''),
                topics=args.get('topics'),
                limit=args.get('limit', 5),
                graph_hops=args.get('graphHops', 1),
                forgetting_lambda=args.get('forgettingLambda', 0.05),
            )
            if result:
                print(json.dumps({'ok': True, 'result': result},
                                 ensure_ascii=False, default=str))
            else:
                _ok(None)
            sys.exit(0)

        elif command == 'batch':
            ops = _parse_json_arg(raw_args) or []
            if not isinstance(ops, list):
                _fail('batch requires a JSON array of operations')
            results = client.batch(ops)
            print(json.dumps({'ok': True, 'results': results},
                             ensure_ascii=False, default=str))
            sys.exit(0)

        else:
            _fail(f'unknown command: {command}')

    except Exception as e:
        _fail(str(e))
    finally:
        client.close()


if __name__ == '__main__':
    main()
