param(
    [Parameter(Mandatory=$true)]
    [string]$Query,
    [string]$McpServerUrl = $(if ($env:N8N_MCP_URL) { $env:N8N_MCP_URL } else { "https://your-n8n-instance.com/mcp-server/http" }),
    [string]$BearerToken = $(if ($env:N8N_BEARER_TOKEN) { $env:N8N_BEARER_TOKEN } else { "YOUR_N8N_MCP_BEARER_TOKEN_HERE" }),
    [switch]$DryRun = $false,
    [switch]$ShowCode = $false
)

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "    ╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "    ║  n8n Workflow Creator - Template Filling + Local SDK         ║" -ForegroundColor Cyan
Write-Host "    ╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""
Write-Host "[usuario] $Query" -ForegroundColor Green

$builderPath = "$PSScriptRoot\n8n-validator\workflow-builder-v2.js"
$templatesPath = "$PSScriptRoot\workflow-templates.json"

Write-Host "  [v3] Ejecutando pipeline..." -ForegroundColor DarkGray
$output = node $builderPath $templatesPath $McpServerUrl $BearerToken $Query 2>&1
    # Timeout de 30 segundos para evitar bloqueos de red

$lines = $output -split "`n"
$jsonLine = $null
for ($i = $lines.Count - 1; $i -ge 0; $i--) {
    if ($lines[$i].Trim().StartsWith('{')) { $jsonLine = $lines[$i].Trim(); break }
}

if (-not $jsonLine) {
    Write-Host "  [X] No se pudo generar workflow" -ForegroundColor Red
    Write-Host $output -ForegroundColor DarkGray
    return
}

$result = $jsonLine | ConvertFrom-Json
if ($result.error) {
    Write-Host "  [X] Error: $($result.error)" -ForegroundColor Red
    if ($result.hint) { Write-Host "  💡 $($result.hint)" -ForegroundColor Yellow }
    return
}

if ($result.success) {
    $mcp = $result.mcpResponse | ConvertFrom-Json
    
    # Si es DryRun, solo mostrar el codigo y no hacer deploy
    if ($DryRun) {
        Write-Host ""
        Write-Host "  🧪 DRY RUN - No se deployo al servidor" -ForegroundColor Yellow
        Write-Host "  📛 Nombre:   $($mcp.name)" -ForegroundColor White
        Write-Host "  📊 Nodos:    $($mcp.nodeCount)" -ForegroundColor White
        if ($result.requiresCredentials) {
            Write-Host ""
            Write-Host "  ⚠️  CREDENCIALES REQUERIDAS:" -ForegroundColor Yellow
            foreach ($cn in $result.credentialNodes) {
                Write-Host "     • $($cn.name) ($($cn.type))" -ForegroundColor Yellow
            }
        }
        if ($ShowCode -or $mcp.nodeCount -eq 0) {
            Write-Host ""
            Write-Host "  📝 CODIGO SDK:" -ForegroundColor Cyan
            # Extraer codigo del output
            $codeStart = $output.IndexOf('"code":')
            if ($codeStart -gt 0) {
                $codeSnippet = $output.Substring($codeStart, [Math]::Min(500, $output.Length - $codeStart))
                Write-Host $codeSnippet -ForegroundColor Gray
            }
        }
        return
    }
    
    Write-Host ""
    Write-Host "  ✅ WORKFLOW CREADO EXITOSAMENTE" -ForegroundColor Green
    Write-Host "  🆔 ID:       $($mcp.workflowId)" -ForegroundColor White
    Write-Host "  📛 Nombre:   $($mcp.name)" -ForegroundColor White
    Write-Host "  📊 Nodos:    $($mcp.nodeCount)" -ForegroundColor White
    Write-Host "  🔗 URL:      $($mcp.url)" -ForegroundColor White
    if ($result.requiresCredentials) {
        Write-Host ""
        Write-Host "  ⚠️  CREDENCIALES REQUERIDAS:" -ForegroundColor Yellow
        foreach ($cn in $result.credentialNodes) {
            Write-Host "     • $($cn.name) ($($cn.type))" -ForegroundColor Yellow
        }
        Write-Host ""
        Write-Host "  💡 Configura las credenciales en n8n antes de activar." -ForegroundColor Cyan
    }
} else {
    Write-Host "  [X] MCP deployment failed" -ForegroundColor Red
}



