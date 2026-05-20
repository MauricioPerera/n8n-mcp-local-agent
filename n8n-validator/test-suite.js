const fs = require('fs');
const path = require('path');
const assert = require('assert');
const { parseWorkflowCode } = require('@n8n/workflow-sdk');

// 1. Load builder and update scripts as strings
const builderStr = fs.readFileSync(path.join(__dirname, 'workflow-builder.js'), 'utf8');
const updateStr = fs.readFileSync(path.join(__dirname, 'update-workflow.js'), 'utf8');

// 2. Extract functions
const validateLocalCode = builderStr.match(/function validateLocal\([\s\S]*?\n}/)[0];
const stripImportsCode = builderStr.match(/function stripImports\([\s\S]*?\n}/)[0];
const fillSlotsWithKVCode = updateStr.match(/function fillSlotsWithKV\([\s\S]*?\n}/)[0];

// Eval them into this context
eval(validateLocalCode);
eval(stripImportsCode);
// Mock varsCache for fillSlotsWithKV
var varsCache = {
    "email_soporte": { value: "soporte@empresa.com", workflows: [] }
};
eval(fillSlotsWithKVCode);

console.log("=== BATERIA DE TESTS NODE.js ===");

// --- TEST: stripImports ---
try {
    const rawCode = `import { something } from 'somewhere';\nconst x = 1;\nexport default workflow('id').add(node);`;
    const cleaned = stripImports(rawCode);
    assert.ok(!cleaned.includes('import'), "stripImports falló al remover imports");
    assert.ok(cleaned.includes('const x = 1'), "stripImports borró código válido");
    console.log("✅ stripImports: OK");
} catch (e) {
    console.error("❌ stripImports: ERROR", e);
}

// --- TEST: validateLocal ---
try {
    // Missing node type
    const invalidCode1 = `export default workflow('id', 'Invalid Workflow').add({ name: 'Node' });`;
    let res1 = validateLocal(invalidCode1);
    assert.strictEqual(res1.valid, false, "validateLocal debía rechazar nodo sin type");
    
    // Good code
    const validCode = `export default workflow('id', 'Slack Workflow').add({ type: 'n8n-nodes-base.slack', version: 1, name: 'Slack' });`;
    let res2 = validateLocal(validCode);
    if (!res2.valid) console.log("validateLocal HINT: " + res2.hint);
    assert.strictEqual(res2.valid, true, "validateLocal debía aceptar código válido");
    assert.strictEqual(res2.requiresCredentials, true, "validateLocal debía detectar Slack credencial");
    console.log("✅ validateLocal: OK");
} catch (e) {
    console.error("❌ validateLocal: ERROR", e);
}

// --- TEST: fillSlotsWithKV ---
try {
    const templateCode = `const email = "{{email_to}}";`;
    const slotValues = {
        "email_to": "__KV_email_soporte__"
    };
    const filled = fillSlotsWithKV(templateCode, slotValues);
    assert.ok(filled.includes('const email = "soporte@empresa.com"'), "fillSlotsWithKV no inyectó el valor correcto de la caché: " + filled);
    console.log("✅ fillSlotsWithKV: OK");
} catch (e) {
    console.error("❌ fillSlotsWithKV: ERROR", e);
}

console.log("================================");
