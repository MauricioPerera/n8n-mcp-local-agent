const fs = require("fs");
const { parseWorkflowCode } = require("@n8n/workflow-sdk");
const { syncTemplates, matchTemplate, extractSlots } = require("./vector-cache");

const TEMPLATES_PATH = process.argv[2] || "../workflow-templates.json";
const MCP_URL = process.argv[3] || "https://ardf.dev/mcp-server/http";
const BEARER = process.argv[4] || "";
const QUERY = process.argv[5] || "create a slack notification webhook";
const OLLAMA_MODEL = process.argv[6] || "qwen2.5:0.5b";

function loadTemplates() {
    const raw = fs.readFileSync(TEMPLATES_PATH, "utf8");
    return JSON.parse(raw.replace(/^\uFEFF/, ""));
}

function detectSlots(templateCode) {
    const slots = [];
    const patterns = [
        { name: "channel", regex: /channel:\s*['"]([^'"]+)['"]/ },
        { name: "text", regex: /text:\s*['"]([^'"]+)['"]/ },
        { name: "url", regex: /url:\s*['"]([^'"]+)['"]/ },
        { name: "to", regex: /to:\s*['"]([^'"]+)['"]/ },
        { name: "subject", regex: /subject:\s*['"]([^'"]+)['"]/ },
    ];
    for (const p of patterns) {
        if (p.regex.test(templateCode)) slots.push(p.name);
    }
    return slots;
}

function fillSlots(templateCode, slotValues) {
    let filled = templateCode;
    for (const [key, val] of Object.entries(slotValues)) {
        const pattern = new RegExp("(" + key + ")\\s*:\\s*['\"]([^'\"]+)['\"]", "g");
        filled = filled.replace(pattern, "$1: '" + val + "'");
    }
    return filled;
}

function stripImports(code) {
    return code.replace(/^\s*import\s+.*?\s+from\s+['"][^'"]+['"];?\s*\n?/gm, "");
}

function validateLocal(code) {
    const cleaned = stripImports(code);
    try {
        const json = parseWorkflowCode(cleaned);
        if (!json.nodes || json.nodes.length === 0) {
            return { valid: false, parsed: true, requiresCredentials: false, credentialNodes: [], hint: "Workflow has no nodes. Must define at least one node." };
        }
        const credentialNodes = [];
        const credPrefixes = [
            "n8n-nodes-base.slack", "n8n-nodes-base.emailSend",
            "n8n-nodes-base.googleSheets", "n8n-nodes-base.notion",
            "n8n-nodes-base.telegram", "n8n-nodes-base.discord",
            "n8n-nodes-base.jira", "n8n-nodes-base.pagerDutyTrigger"
        ];
        for (const node of json.nodes || []) {
            for (const prefix of credPrefixes) {
                if (node.type && node.type.toLowerCase().startsWith(prefix.toLowerCase())) {
                    credentialNodes.push({ name: node.name, type: node.type });
                    break;
                }
            }
        }
        return { valid: true, parsed: true, requiresCredentials: credentialNodes.length > 0, credentialNodes, hint: "" };
    } catch (err) {
        return { valid: false, parsed: false, requiresCredentials: false, credentialNodes: [], hint: err.message };
    }
}

async function generateWithLLM(query, maxAttempts = 3) {
    console.log("[llm-fallback] No template match. Generating with LLM...");
    const basePrompt = `Generate n8n SDK workflow code for: ${query}\n\nRules:\n- Do NOT use import statements\n- Do NOT use new expressions\n- Must have at least a trigger node and one action node\n- Each node needs: type, version, config { name, position }, output\n- End with: export default workflow('id', 'Name').add(trigger).to(node);\n- Only output the code. No markdown fences. No explanations.`;
    const systemPrompt = "You are an expert n8n workflow SDK code generator. Use real n8n node types like n8n-nodes-base.webhook, n8n-nodes-base.slack, n8n-nodes-base.httpRequest, n8n-nodes-base.set, n8n-nodes-base.emailSend, n8n-nodes-base.telegram, n8n-nodes-base.scheduleTrigger, n8n-nodes-base.code, n8n-nodes-base.if.";

    let prompt = basePrompt;
    for (let attempt = 1; attempt <= maxAttempts; attempt++) {
        console.log(`[llm-fallback] Attempt ${attempt}/${maxAttempts}...`);
        const body = JSON.stringify({
            model: OLLAMA_MODEL,
            messages: [
                { role: "system", content: systemPrompt },
                { role: "user", content: prompt }
            ],
            stream: false,
            options: { num_predict: 600, temperature: 0.1 }
        });
        const resp = await fetch("http://localhost:11434/api/chat", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body
        });
        const data = await resp.json();
        if (!data || !data.message || !data.message.content) {
            console.log("[llm-fallback] No response from LLM");
            continue;
        }
        let code = data.message.content.trim();
        code = code.replace(/^```(?:javascript|js)?\s*\n?/gm, "").replace(/```\s*$/gm, "").trim();
        code = code.replace(/^\s*import\s+.*?\s+from\s+['"][^'"]+['"];?\s*\n?/gm, "");
        const validation = validateLocal(code);
        if (validation.valid) {
            console.log("[llm-fallback] Generated code validated successfully");
            return { code, name: "Generated Workflow", description: query };
        }
        console.log(`[llm-fallback] Attempt ${attempt} invalid: ${validation.hint}`);
        if (attempt < maxAttempts) {
            prompt = basePrompt + `\n\nYour previous attempt failed with: ${validation.hint}\nFix it and try again:`;
        }
    }
    return null;
}

async function sendMcp(method, params) {
    if (BEARER === "dryrun") {
        console.log("[dry-run] Simulating MCP response...");
        try {
            const cleaned = stripImports(params.code);
            const json = parseWorkflowCode(cleaned);
            const nodeCount = json.nodes ? json.nodes.length : 0;
            return {
                content: [
                    {
                        type: "text",
                        text: JSON.stringify({
                            workflowId: "dry_run_workflow_id",
                            name: params.name || "Dry Run Workflow",
                            nodeCount: nodeCount,
                            url: "https://ardf.dev/workflow/dry_run_workflow_id"
                        })
                    }
                ]
            };
        } catch (e) {
            return { error: { message: "Dry-run local parse error: " + e.message } };
        }
    }

    const body = JSON.stringify({ jsonrpc: "2.0", id: Math.floor(Math.random() * 1e9), method, params });
    const headers = { "Authorization": "Bearer " + BEARER, "Content-Type": "application/json", "Accept": "application/json, text/event-stream" };
    const resp = await fetch(MCP_URL, { method: "POST", body, headers });
    const text = await resp.text();
    for (const line of text.split("\n")) {
        const m = line.match(/^data:\s*(.+)$/);
        if (m) {
            const obj = JSON.parse(m[1]);
            if (obj.result) return obj.result;
            if (obj.error) return { error: obj.error };
        }
    }
    return null;
}

async function main() {
    console.log("[1] Loading templates...");
    const templates = loadTemplates();
    
    console.log("[2] Syncing vector store templates...");
    await syncTemplates(templates);
    
    console.log("[3] Matching query: " + QUERY);
    const match = await matchTemplate(QUERY, templates);
    
    let code, name, description;
    
    if (match) {
        const template = match.template;
        console.log("    Template: " + template.name);
        const slots = detectSlots(template.code);
        console.log("    Slots to extract: " + slots.join(", "));
        
        console.log("    Extracting slots via micro LLM...");
        const slotValues = await extractSlots(QUERY, slots);
        for (const [k, v] of Object.entries(slotValues)) console.log("    " + k + " = " + v);
        
        code = fillSlots(template.code, slotValues);
        name = template.name;
        description = template.description;
    } else {
        console.log("    No semantic template match. Using LLM fallback...");
        const generated = await generateWithLLM(QUERY);
        if (!generated) {
            console.log(JSON.stringify({ error: "No template match and LLM generation failed" }));
            return;
        }
        code = generated.code;
        name = generated.name;
        description = generated.description;
    }
    
    console.log("[4] Local validation...");
    const validation = validateLocal(code);
    console.log("    Valid: " + validation.valid + " | Creds: " + validation.requiresCredentials);
    if (!validation.valid) {
        console.log(JSON.stringify({ error: "Local validation failed", hint: validation.hint }));
        return;
    }
    if (validation.requiresCredentials) {
        console.log("    Credential nodes:");
        for (const cn of validation.credentialNodes) console.log("      - " + cn.name + " (" + cn.type + ")");
    }
    
    console.log("[5] Deploying via MCP...");
    const mcpResult = await sendMcp("tools/call", {
        name: "create_workflow_from_code",
        arguments: { code, name, description }
    });
    
    if (mcpResult && mcpResult.content) {
        const text = mcpResult.content.filter(c => c.type === "text").map(c => c.text).join("\n");
        console.log(JSON.stringify({ success: true, mcpResponse: text, requiresCredentials: validation.requiresCredentials, credentialNodes: validation.credentialNodes }));
    } else if (mcpResult && mcpResult.error) {
        console.log(JSON.stringify({ success: false, error: mcpResult.error.message }));
    } else {
        console.log(JSON.stringify({ success: false, error: "MCP failed" }));
    }
}

main().catch(e => console.log(JSON.stringify({ error: e.message })));