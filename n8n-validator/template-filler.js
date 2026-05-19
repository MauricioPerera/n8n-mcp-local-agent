const fs = require("fs");
const { parseWorkflowCode } = require("@n8n/workflow-sdk");

function stripImports(code) {
    return code.replace(/^\s*import\s+.*?\s+from\s+['"][^'"]+['"];?\s*\n?/gm, "");
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

function validateCode(code) {
    const cleaned = stripImports(code);
    try {
        const json = parseWorkflowCode(cleaned);
        return { valid: true, json };
    } catch (err) {
        return { valid: false, error: err.message };
    }
}

if (process.argv[2] === "detect") {
    const templateCode = fs.readFileSync(process.argv[3], "utf8");
    const slots = detectSlots(templateCode);
    console.log(JSON.stringify({ slots }));
} else if (process.argv[2] === "fill") {
    const templateCode = fs.readFileSync(process.argv[3], "utf8");
    const slotValues = JSON.parse(process.argv[4] || "{}");
    const filled = fillSlots(templateCode, slotValues);
    const validation = validateCode(filled);
    console.log(JSON.stringify({ filled, validation }, null, 2));
} else {
    console.log(JSON.stringify({ error: "Usage: node template-filler.js detect|fill <file> [slotJSON]" }));
}