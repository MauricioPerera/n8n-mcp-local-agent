param(
    [Parameter(Mandatory=$true)]
    [string]$FilePath
)

if (-not (Test-Path $FilePath)) {
    Write-Error "El archivo '$FilePath' no existe."
    exit 1
}

$ext = [System.IO.Path]::GetExtension($FilePath).ToLower()

if ($ext -eq ".ps1" -or $ext -eq ".psm1") {
    Write-Host "Validando AST de PowerShell para '$FilePath'..." -ForegroundColor Cyan
    $errors = $null
    $tokens = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($FilePath, [ref]$tokens, [ref]$errors)
    if ($errors) {
        Write-Host "❌ Se encontraron $($errors.Count) errores de AST en el script PowerShell:" -ForegroundColor Red
        foreach ($err in $errors) {
            Write-Host "  • [$($err.Extent.StartLineNumber):$($err.Extent.StartColumnNumber)] $($err.Message)" -ForegroundColor Red
        }
        exit 1
    } else {
        Write-Host "✅ El archivo PowerShell '$FilePath' es AST-válido. ¡Sin errores!" -ForegroundColor Green
        exit 0
    }
} elseif ($ext -eq ".js" -or $ext -eq ".json") {
    Write-Host "Validando sintaxis de Workflow JS/JSON para '$FilePath'..." -ForegroundColor Cyan
    
    if ($ext -eq ".json") {
        try {
            $json = Get-Content -Raw -Path $FilePath -Encoding UTF8 | ConvertFrom-Json
            Write-Host "✅ El archivo JSON '$FilePath' tiene sintaxis JSON válida." -ForegroundColor Green
            exit 0
        } catch {
            Write-Host "❌ Error de sintaxis JSON en '$FilePath': $_" -ForegroundColor Red
            exit 1
        }
    }
    
    # Serializar la ruta a JSON para asegurar un escape correcto de barras invertidas
    $escapedPath = $FilePath | ConvertTo-Json -Compress
    
    # Micro-script de Node.js invocando @n8n/workflow-sdk
    $validatorCode = @"
const fs = require('fs');
const { parseWorkflowCode } = require('@n8n/workflow-sdk');
try {
    const code = fs.readFileSync($escapedPath, 'utf8');
    const cleaned = code.replace(/^\s*import\s+.*?\s+from\s+['"][^'"]+['"];?\s*\n?/gm, "");
    parseWorkflowCode(cleaned);
    console.log("OK");
} catch (err) {
    console.error(err.message);
    process.exit(1);
}
"@
    $tempFile = [System.IO.Path]::GetTempFileName() + ".js"
    Set-Content -Path $tempFile -Value $validatorCode -Encoding UTF8
    
    try {
        $output = node $tempFile 2>&1
        $outStr = ($output | Out-String).Trim()
        if ($outStr -eq "OK") {
            Write-Host "✅ El código JS de n8n '$FilePath' es 100% válido sintácticamente." -ForegroundColor Green
            exit 0
        } else {
            Write-Host "❌ Error de validación n8n SDK en '$FilePath':" -ForegroundColor Red
            Write-Host $outStr -ForegroundColor Red
            exit 1
        }
    } finally {
        if (Test-Path $tempFile) { Remove-Item $tempFile -Force }
    }
} else {
    Write-Warning "Tipo de archivo '$ext' no soportado para validación AST. Sólo se soportan .ps1, .psm1, .js, y .json."
    exit 1
}
