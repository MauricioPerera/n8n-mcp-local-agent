# mcp-client-v3.ps1 - Cliente hibrido: Pipeline v3 para creacion, Pipeline v2 para gestion
param(
    [string]$global:McpServerUrl = $(if ($env:N8N_MCP_URL) { $env:N8N_MCP_URL } else { "https://your-n8n-instance.com/mcp-server/http" }),
    [string]$global:BearerToken = $(if ($env:N8N_BEARER_TOKEN) { $env:N8N_BEARER_TOKEN } else { "YOUR_N8N_MCP_BEARER_TOKEN_HERE" }),
    [string]$RouterModel = "qwen2.5:0.5b",
    [string]$EmbedModel = "embeddinggemma:latest",
    [string]$OllamaUrl = "http://localhost:11434",
    [switch]$DryRun = $false
)

$WarningPreference = "SilentlyContinue"

Import-Module "$PSScriptRoot\arg-extractor-v2.psm1" -Force -DisableNameChecking | Out-Null
Import-Module "$PSScriptRoot\local-validator.psm1" -Force -DisableNameChecking | Out-Null
Load-ToolSchemas -schemaJsonPath "$PSScriptRoot\tool-schemas.json"

function Send-McpRequest($Method, $Params = $null) {
    $body = @{ jsonrpc = "2.0"; id = (Get-Random); method = $Method }
    if ($Params -ne $null) { $body['params'] = $Params }
    $json = $body | ConvertTo-Json -Depth 5 -Compress
    $headers = @{ "Authorization" = "Bearer $global:BearerToken"; "Content-Type" = "application/json"; "Accept" = "application/json, text/event-stream" }
    try {
        $resp = Invoke-RestMethod -Uri $global:McpServerUrl -Method Post -Body $json -Headers $headers -TimeoutSec 20
        if ($resp -is [System.Management.Automation.PSCustomObject] -or $resp -is [System.Collections.IDictionary]) {
            if ($resp.error) { return @{ error = $resp.error } }
            if ($resp.result) { return $resp.result }
            return $resp
        } elseif ($resp -is [string]) {
            $lines = $resp -split "`n"
            foreach ($line in $lines) {
                if ($line -match '^data:\s*(.+)$') {
                    $obj = ($matches[1] | ConvertFrom-Json)
                    if ($obj.error) { return @{ error = $obj.error } }
                    if ($obj.result) { return $obj.result }
                }
            }
        } else {
            $respStr = $resp | Out-String
            if ($respStr.Trim().StartsWith("{")) {
                $obj = $respStr | ConvertFrom-Json
                if ($obj.error) { return @{ error = $obj.error } }
                if ($obj.result) { return $obj.result }
                return $obj
            }
        }
        return $null
    } catch { Write-Warning "MCP error: $_"; return $null }
}

function Invoke-CreateWorkflowV3($query) {
    Write-Host "  [v3] Template matching + Local validation + Deploy..." -ForegroundColor DarkGray
    $output = node "$PSScriptRoot\n8n-validator\workflow-builder-v2.js" "$PSScriptRoot\workflow-templates.json" "$global:McpServerUrl" "$global:BearerToken" "$query" 2>&1
    $lines = $output -split "`n"
    $jsonLine = $null
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        if ($lines[$i].Trim().StartsWith('{')) { $jsonLine = $lines[$i].Trim(); break }
    }
    if (-not $jsonLine) {
        Write-Host "  [v3] No se pudo generar workflow" -ForegroundColor Red
        return $null
    }
    $result = $jsonLine | ConvertFrom-Json
    if ($result.error) {
        Write-Host "  [v3] Error: $($result.error)" -ForegroundColor Red
        if ($result.hint) { Write-Host "  💡 $($result.hint)" -ForegroundColor Yellow }
        return $null
    }
    if ($result.success) {
        $mcp = $result.mcpResponse | ConvertFrom-Json
        Write-Host ""
        Write-Host "  ✅ WORKFLOW CREADO" -ForegroundColor Green
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
        return $mcp
    }
    return $null
}

function Invoke-ListWorkflows() {
    $result = Send-McpRequest -Method "tools/call" -Params @{ name = "search_workflows"; arguments = @{ limit = 50 } }
    if ($result -and $result.content) {
        $text = ($result.content | Where-Object { $_.type -eq "text" } | Select-Object -ExpandProperty text) -join ""
        $data = $text | ConvertFrom-Json
        Write-Host ""
        Write-Host "  WORKFLOWS DISPONIBLES" -ForegroundColor Cyan
        $idx = 1
        foreach ($wf in $data.data) {
            $status = if ($wf.active) { "✅" } else { "⬜" }
            Write-Host "  $status $($wf.name) (ID: $($wf.id))" -ForegroundColor White
            $idx++
        }
    }
}

Write-Host ""
Write-Host "    ╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "    ║  n8n MCP CLIENT v3.0 - Pipeline: Template + Local SDK      ║" -ForegroundColor Cyan
Write-Host "    ║  Router: $RouterModel | Embed: $EmbedModel                     ║" -ForegroundColor Cyan
Write-Host "    ╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Comandos:" -ForegroundColor Gray
Write-Host "    create <description>    - Crear workflow desde template" -ForegroundColor White
Write-Host "    list                   - Listar workflows" -ForegroundColor White
Write-Host "    salir | exit           - Terminar" -ForegroundColor White
Write-Host ""

while ($true) {
    Write-Host "[usuario] " -NoNewline -ForegroundColor Green
    $inputText = Read-Host
    if ($inputText -match '^(salir|exit|quit)$') { break }
    if ([string]::IsNullOrWhiteSpace($inputText)) { continue }

    $queryLower = $inputText.ToLower()

    # Comando: list
    if ($queryLower -eq 'list') {
        Invoke-ListWorkflows
        Write-Host "[agente] Hecho." -ForegroundColor Cyan
        continue
    }

    # Comando: create (pipeline v3)
    if ($queryLower.StartsWith('create ') -or $queryLower.StartsWith('build ') -or $queryLower.StartsWith('make ')) {
        if ($DryRun) {
            Write-Host "  [DRY RUN] Simulando creacion..." -ForegroundColor DarkGray
        } else {
            Invoke-CreateWorkflowV3 -query $inputText
        }
        Write-Host "[agente] Hecho." -ForegroundColor Cyan
        continue
    }

    # Fallback: usar pipeline v2 para gestion
    Write-Host "  [v2] Usando pipeline de gestion (embeddings + LLM)..." -ForegroundColor DarkGray
    # Simplificado: asumir search_workflows para todo lo demas
    $result = Send-McpRequest -Method "tools/call" -Params @{ name = "search_workflows"; arguments = @{ limit = 50 } }
    if ($result -and $result.content) {
        $text = ($result.content | Where-Object { $_.type -eq "text" } | Select-Object -ExpandProperty text) -join ""
        $data = $text | ConvertFrom-Json
        if ($data.data.Count -gt 0) {
            Write-Host "  Encontrados $($data.data.Count) workflows" -ForegroundColor Cyan
        } else {
            Write-Host "  Sin workflows" -ForegroundColor Yellow
        }
    }
    Write-Host "[agente] Hecho." -ForegroundColor Cyan
}


