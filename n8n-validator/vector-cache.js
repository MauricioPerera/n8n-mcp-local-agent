const fs = require("fs");
const path = require("path");
const { VectorStore } = require("d:/repos/js-vector-store/js-vector-store.js");

const OLLAMA_URL = "http://localhost:11434";
const EMBED_MODEL = "embeddinggemma:latest";
const CHAT_MODEL = "qwen2.5:0.5b";
const DB_PATH = path.join(__dirname, "../n8n-vector-db");

// Dimensión del modelo embeddinggemma es 768
const store = new VectorStore(DB_PATH, 768);

async function getEmbedding(text) {
    try {
        const resp = await fetch(`${OLLAMA_URL}/api/embed`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ model: EMBED_MODEL, input: text })
        });
        if (!resp.ok) throw new Error("Status: " + resp.status);
        const data = await resp.json();
        return data.embeddings[0];
    } catch (err) {
        console.error(`[vector-cache] Error al obtener embedding para "${text.substring(0, 30)}...":`, err.message);
        return null;
    }
}

async function syncTools(tools) {
    console.log(`[vector-cache] Sincronizando ${tools.length} herramientas...`);
    let updated = 0;
    
    for (const tool of tools) {
        const text = `${tool.name}: ${tool.description}`;
        const existing = store.get("tools", tool.name);
        
        // Si no existe o cambió la descripción, recalculamos
        if (!existing || existing.metadata.description !== tool.description) {
            console.log(`  -> Indexando herramienta: ${tool.name}`);
            const emb = await getEmbedding(text);
            if (emb) {
                store.set("tools", tool.name, emb, { description: tool.description, tool });
                updated++;
            }
        }
    }
    
    if (updated > 0) {
        store.flush();
        console.log(`[vector-cache] Se actualizaron/indexaron ${updated} herramientas.`);
    } else {
        console.log("[vector-cache] Todos los embeddings de herramientas cargados de caché local.");
    }
    
    // Devolvemos el listado completo con sus embeddings
    const results = [];
    for (const tool of tools) {
        const entry = store.get("tools", tool.name);
        if (entry) {
            results.push({
                name: tool.name,
                tool: entry.metadata.tool,
                embedding: entry.vector
            });
        }
    }
    return results;
}

async function syncTemplates(templates) {
    console.log(`[vector-cache] Sincronizando ${Object.keys(templates).length} plantillas...`);
    let updated = 0;
    
    for (const [key, tmpl] of Object.entries(templates)) {
        const text = `${tmpl.name}: ${tmpl.description}`;
        const existing = store.get("templates", key);
        
        if (!existing || existing.metadata.description !== tmpl.description || existing.metadata.name !== tmpl.name) {
            console.log(`  -> Indexando plantilla: ${tmpl.name}`);
            const emb = await getEmbedding(text);
            if (emb) {
                store.set("templates", key, emb, { name: tmpl.name, description: tmpl.description });
                updated++;
            }
        }
    }
    
    if (updated > 0) {
        store.flush();
        console.log(`[vector-cache] Se actualizaron/indexaron ${updated} plantillas.`);
    } else {
        console.log("[vector-cache] Todos los embeddings de plantillas cargados de caché local.");
    }
}

async function matchTemplate(query, templates) {
    const queryEmb = await getEmbedding(query);
    if (!queryEmb) return null;
    
    const results = store.search("templates", queryEmb, 3);
    if (results.length === 0) return null;
    
    const best = results[0];
    console.log(`[vector-cache] Mejor coincidencia semántica: [${best.id}] "${best.metadata.name}" (Score: ${(best.score * 100).toFixed(1)}%)`);
    
    // Consideramos un score de similitud coseno aceptable >= 0.35 para embeddinggemma
    if (best.score >= 0.35) {
        return {
            key: best.id,
            template: templates[best.id],
            score: best.score
        };
    }
    return null;
}

async function extractSlots(query, slots, variables = []) {
    let varsHint = "";
    if (variables && variables.length > 0) {
        varsHint = `\n\nAVAILABLE VARIABLES:\nThe user has defined the following reusable KV variables: [${variables.join(", ")}].\nIf the user's query implies they want to use one of these variables, you MUST extract the value as "__KV_variablename__" instead of guessing the literal text. For example, if the query says "usa la variable email para el destino", output {"to": "__KV_email__"}.`;
    }

    const systemPrompt = `You are a strict data extraction assistant.
Given a user query and a list of target slot names, extract the appropriate values from the query.
Return ONLY a raw JSON object mapping slot names to extracted string values.
Do NOT wrap the JSON in markdown code blocks. Do NOT add any conversational text or explanations.
If a slot is not present or cannot be extracted, omit it from the JSON object.
${varsHint}

Example 1:
Query: "envía un correo a soporte@empresa.com con el asunto Servidor Caído"
Slots: ["to", "subject"]
Output: {"to": "soporte@empresa.com", "subject": "Servidor Caído"}

Example 2:
Query: "avísame al canal de alertas que el servicio se detuvo"
Slots: ["channel", "text"]
Output: {"channel": "#alertas", "text": "el servicio se detuvo"}`;

    const prompt = `Query: "${query}"\nSlots to extract: ${JSON.stringify(slots)}`;
    
    try {
        const resp = await fetch(`${OLLAMA_URL}/api/chat`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({
                model: CHAT_MODEL,
                messages: [
                    { role: "system", content: systemPrompt },
                    { role: "user", content: prompt }
                ],
                stream: false,
                options: { temperature: 0.0, num_predict: 150 }
            })
        });
        if (!resp.ok) throw new Error("Ollama status: " + resp.status);
        const data = await resp.json();
        const text = data.message.content.trim();
        const cleaned = text.replace(/^```(?:json)?\s*\n?/i, "").replace(/```\s*$/i, "").trim();
        return JSON.parse(cleaned);
    } catch (err) {
        console.error("[vector-cache] Falló la extracción semántica de slots:", err.message);
        return {};
    }
}

module.exports = {
    syncTools,
    syncTemplates,
    matchTemplate,
    extractSlots,
    getEmbedding
};
