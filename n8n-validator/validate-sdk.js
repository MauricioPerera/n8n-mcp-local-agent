const { parseWorkflowCode, validateWorkflow } = require('@n8n/workflow-sdk');

function stripImports(code) {
    return code.replace(/^\s*import\s+.*?\s+from\s+['"][^'"]+['"];?\s*\n?/gm, '');
}

function validate(code) {
    const cleaned = stripImports(code);
    let json = null;
    try {
        json = parseWorkflowCode(cleaned);
    } catch (err) {
        console.log(JSON.stringify({
            valid: false,
            parsed: false,
            errors: [{ code: 'PARSE_ERROR', message: err.message }],
            warnings: [],
            hint: err.message,
            requiresCredentials: false,
            credentialNodes: []
        }, null, 2));
        return;
    }

    if (!json.nodes || json.nodes.length === 0) {
        console.log(JSON.stringify({
            valid: false, parsed: true,
            errors: [{ code: 'EMPTY_WORKFLOW', message: 'Workflow has no nodes. The generated code must define at least one node.' }],
            warnings: [], hint: 'LLM generated empty workflow — retry or use a template.',
            requiresCredentials: false, credentialNodes: []
        }, null, 2));
        return;
    }

    try {
        const result = validateWorkflow(json, { strictMode: true, validateSchema: true });
        const errors = (result.errors || []).map(e => ({
            code: e.code,
            message: e.message,
            nodeName: e.nodeName,
            parameterName: e.parameterName,
            level: e.violationLevel || 'error'
        }));
        const warnings = (result.warnings || []).map(w => ({
            code: w.code,
            message: w.message,
            nodeName: w.nodeName,
            parameterPath: w.parameterPath,
            level: w.violationLevel || 'warning'
        }));
        const credentialNodes = [];
        const nodeTypesNeedingCreds = [
            'n8n-nodes-base.slack', 'n8n-nodes-base.emailSend',
            'n8n-nodes-base.googleSheets', 'n8n-nodes-base.notion',
            'n8n-nodes-base.airtable', 'n8n-nodes-base.telegram',
            'n8n-nodes-base.discord', 'n8n-nodes-base.jira',
            'n8n-nodes-base.gitlab', 'n8n-nodes-base.github',
            'n8n-nodes-base.asana', 'n8n-nodes-base.trello',
        ];
        for (const node of json.nodes || []) {
            for (const prefix of nodeTypesNeedingCreds) {
                if (node.type && node.type.toLowerCase().startsWith(prefix.toLowerCase())) {
                    credentialNodes.push({ name: node.name, type: node.type });
                    break;
                }
            }
        }
        console.log(JSON.stringify({
            valid: errors.length === 0,
            parsed: true,
            errors,
            warnings,
            hint: errors.length > 0 ? errors[0].message : (warnings.length > 0 ? warnings[0].message : ''),
            requiresCredentials: credentialNodes.length > 0,
            credentialNodes
        }, null, 2));
    } catch (err) {
        console.log(JSON.stringify({
            valid: false,
            parsed: true,
            errors: [{ code: 'VALIDATE_ERROR', message: err.message }],
            warnings: [],
            hint: err.message,
            requiresCredentials: false,
            credentialNodes: []
        }, null, 2));
    }
}

// Read from file arg if provided, otherwise stdin
const fs = require('fs');
const fileArg = process.argv[2];
if (fileArg) {
    validate(fs.readFileSync(fileArg, 'utf8'));
} else {
    let code = '';
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', chunk => { code += chunk; });
    process.stdin.on('end', () => { validate(code); });
}
