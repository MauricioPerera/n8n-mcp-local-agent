const fs = require("fs");
const path = require("path");
const { DocStore, FileStorageAdapter, EncryptedAdapter } = require("d:/repos/js-doc-store/js-doc-store.js");

// Database directory
const DB_DIR = path.join(__dirname, "../n8n-executions-db");

let db = null;
let adapter = null;

// Initialize the database with optional encryption password
async function initDb(password = null) {
    if (!fs.existsSync(DB_DIR)) {
        fs.mkdirSync(DB_DIR, { recursive: true });
    }
    
    let baseAdapter = new FileStorageAdapter(DB_DIR);
    
    if (password) {
        adapter = await EncryptedAdapter.create(baseAdapter, password);
        // Preload files if they exist to decrypt in memory
        await adapter.preload([
            "executions.docs.json", "executions.meta.json",
            "workflows.docs.json", "workflows.meta.json"
        ]);
        
        // Verificación de contraseña incorrecta o migración automática
        const testFile = path.join(DB_DIR, "executions.docs.json");
        if (fs.existsSync(testFile)) {
            const raw = fs.readFileSync(testFile, "utf8");
            if (raw.includes("__enc")) {
                if (adapter.readJson("executions.docs.json") === null) {
                    throw new Error("Password incorrecto: Error al descifrar la base de datos.");
                }
            } else {
                // Es texto plano! Vamos a migrarlo
                try {
                    const parsed = JSON.parse(raw);
                    if (Array.isArray(parsed)) {
                        console.log("[secure] Base de datos en texto plano detectada. Migrando a cifrada...");
                        
                        // Cargar datos plano primero
                        const plainDb = new DocStore(baseAdapter);
                        const plainExecutions = plainDb.collection("executions").find().toArray();
                        const plainWorkflows = plainDb.collection("workflows").find().toArray();
                        
                        // Eliminar archivos plano de disco
                        const filesToDelete = [
                            "executions.docs.json", "executions.meta.json",
                            "executions.startedAt.sidx.json", "executions.status.idx.json", "executions.workflowId.idx.json",
                            "workflows.docs.json", "workflows.meta.json", "workflows.name.idx.json"
                        ];
                        for (const f of filesToDelete) {
                            const p = path.join(DB_DIR, f);
                            if (fs.existsSync(p)) fs.unlinkSync(p);
                        }
                        
                        // Reiniciar con EncryptedAdapter
                        adapter = await EncryptedAdapter.create(baseAdapter, password);
                        db = new DocStore(adapter);
                        
                        db.collection("executions").insertMany(plainExecutions);
                        db.collection("workflows").insertMany(plainWorkflows);
                        
                        db.flush();
                        await adapter.persist();
                        console.log("[secure] Migración completada. Base de datos cifrada guardada.");
                    }
                } catch (migrationErr) {
                    console.error("[secure] Error durante la migración:", migrationErr.message);
                }
            }
        }
    } else {
        adapter = baseAdapter;
    }
    
    db = new DocStore(adapter);
    
    // Ensure indexes are set up on collections
    const executions = db.collection("executions");
    const workflows = db.collection("workflows");
    
    // Check and create indexes if needed
    const execIndexes = executions.getIndexes();
    if (!execIndexes.some(idx => idx.field === "workflowId")) {
        executions.createIndex("workflowId");
    }
    if (!execIndexes.some(idx => idx.field === "startedAt")) {
        executions.createIndex("startedAt", { type: "sorted" });
    }
    if (!execIndexes.some(idx => idx.field === "status")) {
        executions.createIndex("status");
    }
    
    const wfIndexes = workflows.getIndexes();
    if (!wfIndexes.some(idx => idx.field === "name")) {
        workflows.createIndex("name");
    }
}

// Fetch workflows from n8n API and cache them
async function syncWorkflows(apiKey, baseUrl) {
    const url = `${baseUrl}/api/v1/workflows`;
    console.log(`[sync] Sincronizando workflows desde ${url}...`);
    
    const resp = await fetch(url, {
        headers: {
            "X-N8N-API-KEY": apiKey,
            "Accept": "application/json"
        }
    });
    
    if (!resp.ok) {
        throw new Error(`n8n API returned status ${resp.status}`);
    }
    
    const body = await resp.json();
    const items = body.data || [];
    
    const collection = db.collection("workflows");
    let added = 0;
    let updated = 0;
    
    for (const wf of items) {
        const existing = collection.findById(wf.id);
        const doc = {
            _id: wf.id,
            id: wf.id,
            name: wf.name,
            active: wf.active,
            createdAt: wf.createdAt,
            updatedAt: wf.updatedAt
        };
        
        if (!existing) {
            collection.insert(doc);
            added++;
        } else if (existing.name !== wf.name || existing.active !== wf.active) {
            collection.update({ _id: wf.id }, { $set: { name: wf.name, active: wf.active, updatedAt: wf.updatedAt } });
            updated++;
        }
    }
    
    console.log(`[sync] Sincronizados ${items.length} workflows. (Nuevos: ${added}, Actualizados: ${updated})`);
}

// Fetch executions from n8n API and cache them
async function syncExecutions(apiKey, baseUrl, limit = 100) {
    const url = `${baseUrl}/api/v1/executions?limit=${limit}`;
    console.log(`[sync] Sincronizando ejecuciones desde ${url}...`);
    
    const resp = await fetch(url, {
        headers: {
            "X-N8N-API-KEY": apiKey,
            "Accept": "application/json"
        }
    });
    
    if (!resp.ok) {
        throw new Error(`n8n API returned status ${resp.status}`);
    }
    
    const body = await resp.json();
    const items = body.data || [];
    
    const collection = db.collection("executions");
    let added = 0;
    let updated = 0;
    
    for (const ex of items) {
        const existing = collection.findById(ex.id);
        
        // Calculate duration and numeric flags for fast aggregation
        const started = new Date(ex.startedAt);
        const stopped = ex.stoppedAt ? new Date(ex.stoppedAt) : null;
        const durationSec = stopped ? Math.round((stopped - started) / 1000) : 0;
        
        const doc = {
            _id: ex.id,
            id: ex.id,
            workflowId: ex.workflowId,
            status: ex.status || "unknown",
            finished: !!ex.finished,
            startedAt: ex.startedAt,
            stoppedAt: ex.stoppedAt || null,
            durationSeconds: durationSec,
            isSuccess: ex.status === "success" ? 1 : 0,
            isFailed: ex.status === "failed" ? 1 : 0,
            mode: ex.mode || "unknown"
        };
        
        if (!existing) {
            collection.insert(doc);
            added++;
        } else if (existing.status !== ex.status || existing.finished !== doc.finished) {
            collection.update(
                { _id: ex.id },
                {
                    $set: {
                        status: doc.status,
                        finished: doc.finished,
                        stoppedAt: doc.stoppedAt,
                        durationSeconds: doc.durationSeconds,
                        isSuccess: doc.isSuccess,
                        isFailed: doc.isFailed
                    }
                }
            );
            updated++;
        }
    }
    
    console.log(`[sync] Sincronizadas ${items.length} ejecuciones. (Nuevas: ${added}, Actualizados: ${updated})`);
    
    // Save to disk (and encrypt if using EncryptedAdapter)
    db.flush();
    if (adapter.persist) {
        await adapter.persist();
    }
    
    console.log(`[sync] Guardado en base de datos local.`);
}

// List executions joined with workflow names
function listExecutions(limit = 20) {
    const collection = db.collection("executions");
    const results = collection.aggregate()
        .lookup({
            from: "workflows",
            localField: "workflowId",
            foreignField: "_id",
            as: "workflow",
            single: true
        })
        .sort({ startedAt: -1 })
        .limit(limit)
        .toArray();
    
    return results;
}

// Filter executions locally using mongo-style query
function filterExecutions(queryField, queryVal, limit = 20) {
    const collection = db.collection("executions");
    const filter = {};
    
    if (queryField === "finished" || queryField === "success") {
        filter[queryField] = queryVal === "true" || queryVal === "1";
    } else {
        filter[queryField] = queryVal;
    }
    
    const results = collection.aggregate()
        .match(filter)
        .lookup({
            from: "workflows",
            localField: "workflowId",
            foreignField: "_id",
            as: "workflow",
            single: true
        })
        .sort({ startedAt: -1 })
        .limit(limit)
        .toArray();
        
    return results;
}

// Calculate aggregated execution metrics
function getAggregatedStats() {
    const collection = db.collection("executions");
    
    const stats = collection.aggregate()
        .lookup({
            from: "workflows",
            localField: "workflowId",
            foreignField: "_id",
            as: "workflow",
            single: true
        })
        .group("workflowId", {
            totalRuns: { $count: true },
            successCount: { $sum: "isSuccess" },
            failedCount: { $sum: "isFailed" },
            avgDurationSeconds: { $avg: "durationSeconds" },
            workflowName: { $first: "workflow.name" }
        })
        .sort({ totalRuns: -1 })
        .toArray();
        
    return stats;
}

// CLI Command router
async function main() {
    const args = process.argv.slice(2);
    if (args.length === 0) {
        console.log(JSON.stringify({ error: "Comando requerido (sync|list|filter|stats)" }));
        return;
    }
    
    let cmd = args[0];
    let password = null;
    let cmdArgs = args.slice(1);
    
    // Check if running in encrypted/secure mode
    if (cmd === "secure") {
        password = args[1];
        cmd = args[2];
        cmdArgs = args.slice(3);
        if (!password || !cmd) {
            console.log(JSON.stringify({ error: "Modo seguro requiere contraseña y comando posterior" }));
            return;
        }
    }
    
    try {
        await initDb(password);
        if (cmd === "sync") {
            const apiKey = cmdArgs[0];
            const baseUrl = cmdArgs[1] || "https://ardf.dev";
            if (!apiKey) {
                console.log(JSON.stringify({ error: "Falta API Key para sincronizar" }));
                return;
            }
            await syncWorkflows(apiKey, baseUrl);
            await syncExecutions(apiKey, baseUrl);
            console.log(JSON.stringify({ success: true, message: "Base de datos sincronizada exitosamente" }));
            
        } else if (cmd === "list") {
            const limit = parseInt(cmdArgs[0]) || 20;
            const list = listExecutions(limit);
            console.log(JSON.stringify({ success: true, count: list.length, data: list }));
            
        } else if (cmd === "filter") {
            const field = cmdArgs[0];
            const val = cmdArgs[1];
            const limit = parseInt(cmdArgs[2]) || 20;
            if (!field || val === undefined) {
                console.log(JSON.stringify({ error: "Filtrar requiere campo y valor (ej. status failed)" }));
                return;
            }
            const filtered = filterExecutions(field, val, limit);
            console.log(JSON.stringify({ success: true, count: filtered.length, data: filtered }));
            
        } else if (cmd === "stats") {
            const stats = getAggregatedStats();
            console.log(JSON.stringify({ success: true, data: stats }));
            
        } else {
            console.log(JSON.stringify({ error: `Comando desconocido: ${cmd}` }));
        }
    } catch (err) {
        console.log(JSON.stringify({ success: false, error: err.message }));
    }
}

main();
