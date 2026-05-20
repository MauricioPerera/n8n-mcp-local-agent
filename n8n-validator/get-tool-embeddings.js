const { syncTools } = require("./vector-cache");

async function main() {
    let rawInput = "";
    
    // Si se pasa como argumento de archivo
    const fs = require("fs");
    const fileArg = process.argv[2];
    if (fileArg) {
        rawInput = fs.readFileSync(fileArg, "utf8");
    } else {
        // Leer de stdin
        await new Promise((resolve) => {
            process.stdin.setEncoding("utf8");
            process.stdin.on("data", chunk => { rawInput += chunk; });
            process.stdin.on("end", resolve);
        });
    }
    
    if (!rawInput.trim()) {
        console.error("Error: No input provided to get-tool-embeddings.js");
        process.exit(1);
    }
    
    try {
        const cleanInput = rawInput.replace(/^\uFEFF/, "");
        const tools = JSON.parse(cleanInput);
        const embeddedTools = await syncTools(tools);
        // Imprimir el JSON a stdout para que PowerShell lo recoja
        console.log(JSON.stringify(embeddedTools));
    } catch (err) {
        console.error("Error parsing input tools JSON or syncing embeddings:", err.message);
        process.exit(1);
    }
}

main().catch(e => {
    console.error("Fatal in get-tool-embeddings.js:", e.message);
    process.exit(1);
});
