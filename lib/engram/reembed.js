#!/usr/bin/env node
// ============================================================
// lib/engram/reembed.js — 批量修复缺失的 vector embeddings
//
// 用法: node lib/engram/reembed.js [--dry-run] [--limit N]
// ============================================================

const path = require('path');

// Resolve engram-sdk path — hardcoded fallback for known installs
const home = require('os').homedir();
const fs = require('fs');
let engramPath;

// Check known locations
const candidates = [
    path.join(home, '.nvm/versions/node/v22.22.0/lib/node_modules/engram-sdk'),
    path.join(home, '.nvm/versions/node/v20.19.4/lib/node_modules/engram-sdk'),
];
try {
    const nvmDir = process.env.NVM_DIR || path.join(home, '.nvm');
    const versionsDir = path.join(nvmDir, 'versions/node');
    if (fs.existsSync(versionsDir)) {
        for (const v of fs.readdirSync(versionsDir)) {
            candidates.push(path.join(versionsDir, v, 'lib/node_modules/engram-sdk'));
        }
    }
} catch {}

for (const c of candidates) {
    if (fs.existsSync(path.join(c, 'dist/vault.js'))) {
        engramPath = c;
        break;
    }
}

if (!engramPath) {
    console.error('Cannot find engram-sdk. Tried:');
    candidates.forEach(c => console.error('  ' + c));
    process.exit(1);
}

async function main() {
    const args = process.argv.slice(2);
    const dryRun = args.includes('--dry-run');
    const limitIdx = args.indexOf('--limit');
    const limit = limitIdx >= 0 ? parseInt(args[limitIdx + 1]) : null;

    // Import engram modules
    const { Vault } = await import(path.join(engramPath, 'dist/vault.js'));
    const { OllamaEmbeddings } = await import(path.join(engramPath, 'dist/embeddings.js'));

    const ollamaModel = process.env.ENGRAM_OLLAMA_MODEL || 'qwen3-embedding:4b';
    const ollamaDims = parseInt(process.env.ENGRAM_OLLAMA_DIMS || '2560');
    const ollamaUrl = process.env.ENGRAM_OLLAMA_URL || 'http://localhost:11434';
    const dbPath = process.env.ENGRAM_DB_PATH || path.join(require('os').homedir(), '.engram/default.db');

    const embedder = new OllamaEmbeddings(ollamaModel, ollamaDims, ollamaUrl);
    const vault = new Vault({ owner: 'default', dbPath }, embedder);

    // Find unembedded memories
    // vault.store.db is better-sqlite3 (no vec0), but vault.store has vecEnabled flag
    const db = vault.store.db;
    const vecEnabled = vault.store.vecEnabled;

    if (!vecEnabled) {
        console.log('⚠️  sqlite-vec 扩展未加载，无法修复');
        process.exit(0);
    }

    // Get all active memories
    const allMemories = db.prepare(
        "SELECT id, content, type, salience FROM memories WHERE status = 'active' ORDER BY created_at DESC"
    ).all();

    // Get memories with embeddings (vec0 virtual table queryable with extension loaded)
    const embedded = new Set();
    const embRows = db.prepare("SELECT memory_id FROM vec_memories").all();
    embRows.forEach(r => embedded.add(r.memory_id));

    const unembedded = allMemories.filter(m => !embedded.has(m.id));

    if (limit) {
        unembedded.splice(limit);
    }

    console.log(`🔍 总记忆: ${allMemories.length} | 有embedding: ${embedded.size} | 缺失: ${unembedded.length}`);

    if (unembedded.length === 0) {
        console.log('✅ 全部记忆都有 embedding！');
        process.exit(0);
    }

    if (dryRun) {
        console.log('\n--- Dry Run 预览（前10条）---');
        unembedded.slice(0, 10).forEach(m => {
            console.log(`  [${m.type}] ${m.content.substring(0, 80)}...`);
        });
        process.exit(0);
    }

    // Generate embeddings and store
    console.log(`\n🔧 开始修复 ${unembedded.length} 条...`);
    let success = 0;
    let fail = 0;

    for (let i = 0; i < unembedded.length; i++) {
        const m = unembedded[i];
        const preview = m.content.substring(0, 60);
        try {
            const embedding = await embedder.embed(m.content);
            vault.store.storeEmbedding(m.id, embedding);
            success++;
            if ((i + 1) % 10 === 0 || i === unembedded.length - 1) {
                console.log(`  [${i+1}/${unembedded.length}] ${preview}... ✅ (${success} 成功, ${fail} 失败)`);
            }
        } catch (e) {
            fail++;
            console.log(`  [${i+1}/${unembedded.length}] ${preview}... ❌ ${e.message}`);
        }
    }

    console.log(`\n📊 修复完成: ${success} 成功, ${fail} 失败`);
}

main().catch(e => {
    console.error('Fatal:', e.message);
    process.exit(1);
});
