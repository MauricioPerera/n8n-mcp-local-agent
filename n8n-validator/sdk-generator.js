const { parseWorkflowCode } = require("@n8n/workflow-sdk");

function stripImports(code) {
    return code.replace(/^\s*import\s+.*?\s+from\s+['"][^'"]+['"];?\s*\n?/gm, "");
}

function validateLocal(code) {
    const cleaned = stripImports(code);
    try {
        const json = parseWorkflowCode(cleaned);
        return { valid: true, error: null };
    } catch (err) {
        return { valid: false, error: err.message };
    }
}

async function callOllama(prompt, model = "qwen2.5:0.5b") {
    const body = JSON.stringify({
        model,
        messages: [
            { role: "system", content: "You are an expert n8n workflow SDK code generator. You write valid JavaScript code for n8n workflows using the SDK. CRITICAL RULES:\n- Do NOT use 'import' statements\n- Do NOT use 'new' expressions (no new Date(), no new anything)\n- Each node needs: type, version, config { name, position }, output\n- End with: export default workflow('id', 'Name').add(trigger).to(node);\n- Use ONLY these real n8n node types:\n  * n8n-nodes-base.webhook (trigger)\n  * n8n-nodes-base.slack\n  * n8n-nodes-base.emailSend\n  * n8n-nodes-base.telegram\n  * n8n-nodes-base.discord\n  * n8n-nodes-base.httpRequest\n  * n8n-nodes-base.scheduleTrigger\n  * n8n-nodes-base.set\n  * n8n-nodes-base.googleSheets\n  * n8n-nodes-base.notion\n  * n8n-nodes-base.if\n  * n8n-nodes-base.code\n- Only output the code. No markdown fences. No explanations." },
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
    if (data && data.message && data.message.content) {
        return data.message.content.trim();
    }
    return null;
}

function extractCode(text) {
    text = text.replace(/^```(?:javascript|js)?\s*\n?/gm, "").replace(/```\s*$/gm, "").trim();
    text = text.replace(/^\s*import\s+.*?\s+from\s+['"][^'"]+['"];?\s*\n?/gm, "");
    return text.trim();
}

async function generateWorkflowCode(query, maxAttempts = 3) {
    let prompt = `Generate n8n SDK workflow code for: ${query}\n\nRequirements:\n- Must have at least a trigger node and one action node\n- Use real n8n node types from the allowed list\n- No import statements\n- No new expressions\n\nExample pattern:\nconst triggerNode = trigger({\n  type: 'n8n-nodes-base.webhook',\n  version: 2.1,\n  config: { name: 'Trigger', position: [240, 200] },\n  output: [{}]\n});\n\nconst actionNode = node({\n  type: 'n8n-nodes-base.slack',\n  version: 2.2,\n  config: { name: 'Send Slack', position: [640, 200], parameters: { channel: '#general', text: 'Hello!' } },\n  output: [{}]\n});\n\nexport default workflow('my-workflow', 'My Workflow')\n  .add(triggerNode)\n  .to(actionNode);`;

    let code = null;
    for (let attempt = 1; attempt <= maxAttempts; attempt++) {
        console.log(`[generator] Attempt ${attempt}/${maxAttempts}...`);
        const response = await callOllama(prompt);
        if (!response) {
            console.log("[generator] No response from LLM");
            continue;
        }
        code = extractCode(response);
        const validation = validateLocal(code);
        if (validation.valid) {
            console.log("[generator] Code validated successfully");
            return { success: true, code };
        }
        console.log(`[generator] Validation failed: ${validation.error}`);
        prompt += `\n\nYour previous code failed validation with this error:\n${validation.error}\n\nFix the code and try again:`;
    }
    return { success: false, error: "Failed after " + maxAttempts + " attempts", lastCode: code };
}

const query = process.argv[2];
if (!query) {
    console.log(JSON.stringify({ error: "Usage: node sdk-generator.js '<query>'" }));
    process.exit(1);
}

generateWorkflowCode(query).then(result => {
    console.log(JSON.stringify(result, null, 2));
}).catch(e => {
    console.log(JSON.stringify({ error: e.message }));
});