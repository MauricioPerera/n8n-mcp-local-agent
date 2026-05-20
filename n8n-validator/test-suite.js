const assert = require('assert');
const { validateLocal, stripImports } = require("./workflow-builder-v2");
const { fillSlotsWithKV } = require("./update-workflow");

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
    const mockVarsCache = {
        "email_soporte": { value: "soporte@empresa.com", workflows: [] }
    };
    const filled = fillSlotsWithKV(templateCode, slotValues, mockVarsCache);
    assert.ok(filled.includes('const email = "soporte@empresa.com"'), "fillSlotsWithKV no inyectó el valor correcto de la caché: " + filled);
    console.log("✅ fillSlotsWithKV: OK");
} catch (e) {
    console.error("❌ fillSlotsWithKV: ERROR", e);
}

console.log("================================");
