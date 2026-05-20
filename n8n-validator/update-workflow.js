const fs = require("fs");
const path = require("path");

const mcpServerUrl = process.argv[2];
const bearerToken = process.argv[3];
const targetKey = process.argv[4];

if (!mcpServerUrl || !bearerToken || !targetKey) {
    console.error("Usage: node update-workflow.js <mcpServerUrl> <bearerToken> <key>");
    process.exit(1);
}

const configPath = path.join(__dirname, "../n8n-executions-db/config.json");
if (!fs.existsSync(configPath)) {
    console.error("No config.json found.");
    process.exit(1);
}

let config = {};
try {
    const raw = fs.readFileSync(configPath, "utf8");
    config = JSON.parse(raw.replace(/^\uFEFF/, ""));
} catch (e) {
    console.error("Failed to parse config.json: " + e.message);
    process.exit(1);
}

const varsCache = config.VariablesCache || {};
const localWorkflows = config.LocalWorkflowsCache || {};
const templatesPath = path.join(__dirname, "../workflow-templates.json");
let templates = [];
try {
    templates = JSON.parse(fs.readFileSync(templatesPath, "utf8"));
} catch (e) {
    console.error("Failed to read templates: " + e.message);
    process.exit(1);
}

if (!varsCache[targetKey] || !varsCache[targetKey].workflows) {
    console.log(`No workflows depend on '${targetKey}'.`);
    process.exit(0);
}

const dependentWorkflows = varsCache[targetKey].workflows;

function fillSlotsWithKV(code, slotValues) {
    let result = code;
    for (const [key, rawVal] of Object.entries(slotValues)) {
        let val = rawVal;
        // Check if value is a KV reference
        if (val && typeof val === "string" && val.startsWith("__KV_")) {
            let k = val.substring(5);
            if (k.endsWith("__")) k = k.substring(0, k.length - 2);
            
            if (varsCache[k]) {
                val = varsCache[k].value;
            } else {
                val = ""; // fallback
            }
        }
        
        // Ensure string is properly escaped for JS string literal
        if (typeof val === "string") {
            val = val.replace(/\\/g, '\\\\').replace(/'/g, "\\'").replace(/\n/g, '\\n');
        }
        
        const regex = new RegExp(`{{${key}}}`, "g");
        result = result.replace(regex, val);
    }
    return result;
}

async function autoLinkCredentialsCode(code) {
    const credCache = config.CredentialsCache || [];
    if (credCache.length === 0) return code;
    
    let modifiedCode = code;
    const credPrefixes = [
        "n8n-nodes-base.slack", "n8n-nodes-base.emailSend",
        "n8n-nodes-base.googleSheets", "n8n-nodes-base.notion",
        "n8n-nodes-base.telegram", "n8n-nodes-base.discord",
        "n8n-nodes-base.jira", "n8n-nodes-base.pagerDutyTrigger"
    ];
    
    const CREDENTIAL_MAPPING = {
        "n8n-nodes-base.slack": "slackApi",
        "n8n-nodes-base.emailsend": "smtp",
        "n8n-nodes-base.googlesheets": "googleSheetsOAuth2Api",
        "n8n-nodes-base.notion": "notionApi",
        "n8n-nodes-base.telegram": "telegramApi",
        "n8n-nodes-base.discord": "discordNodeApi",
        "n8n-nodes-base.jira": "jiraSoftwareServerApi",
        "n8n-nodes-base.pagerdutytrigger": "pagerDutyApi"
    };

    // VERY simplistic linking for automated cascaded update
    for (const prefix of credPrefixes) {
        if (!modifiedCode.toLowerCase().includes(prefix.toLowerCase())) continue;
        
        const credType = CREDENTIAL_MAPPING[prefix.toLowerCase()];
        if (!credType) continue;
        
        const matchingCreds = credCache.filter(c => c.type === credType && c.env !== "sandbox" && c.env !== "test");
        if (matchingCreds.length === 0) continue;
        
        const matchedCred = matchingCreds[0];
        const regex = new RegExp("type:\\s*['\"]" + prefix + "['\"]\\s*,?", "i");
        
        if (regex.test(modifiedCode)) {
            const replacement = `type: '${prefix}',\n  credentials: {\n    ${credType}: {\n      id: '${matchedCred.id}',\n      name: '${matchedCred.name}'\n    }\n  },`;
            modifiedCode = modifiedCode.replace(regex, replacement);
        }
    }
    return modifiedCode;
}

async function sendMcp(method, params) {
    const body = JSON.stringify({
        jsonrpc: "2.0",
        id: Math.floor(Math.random() * 10000),
        method,
        params
    });
    
    const resp = await fetch(mcpServerUrl, {
        method: "POST",
        headers: {
            "Authorization": `Bearer ${bearerToken}`,
            "Content-Type": "application/json"
        },
        body
    });
    return await resp.json();
}

async function main() {
    let successCount = 0;
    for (const wId of dependentWorkflows) {
        const wfCache = localWorkflows[wId];
        if (!wfCache) {
            console.log(`[WARN] Workflow ${wId} not found in LocalWorkflowsCache.`);
            continue;
        }
        
        const templateId = wfCache.templateId;
        const slotValues = wfCache.slotValues;
        
        const template = templates.find(t => (t.id === templateId || t.name === templateId));
        if (!template) {
            console.log(`[WARN] Template '${templateId}' not found for workflow ${wId}.`);
            continue;
        }
        
        console.log(`[UPDATE] Regenerating workflow ${wId}...`);
        
        let code = fillSlotsWithKV(template.code, slotValues);
        code = await autoLinkCredentialsCode(code);
        
        const mcpParams = {
            workflowId: wId,
            code: code
        };
        
        const resp = await sendMcp("update_workflow", mcpParams);
        if (resp.error) {
            console.error(`[ERROR] Failed to update workflow ${wId}:`, resp.error.message);
        } else if (resp.result) {
            console.log(`[OK] Workflow ${wId} updated successfully.`);
            successCount++;
        }
    }
    console.log(`Cascade update complete. Updated ${successCount}/${dependentWorkflows.length} workflows.`);
}

main().catch(e => console.error(e));
