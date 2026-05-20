# mcp-client-n8n-final.ps1 - Cliente n8n MCP v2.0
# Pipeline: Regex cluster -> Embeddings top-N (cache) -> qwen2.5:0.5b (con retry) -> Guardrails -> Strict Schema Validator -> Ejecucion
param(
    [string]$McpServerUrl = $(if ($env:N8N_MCP_URL) { $env:N8N_MCP_URL } else { "https://your-n8n-instance.com/mcp-server/http" }),
    [string]$BearerToken = $(if ($env:N8N_BEARER_TOKEN) { $env:N8N_BEARER_TOKEN } else { "YOUR_N8N_MCP_BEARER_TOKEN_HERE" }),
    [string]$RouterModel = "qwen2.5:0.5b",
    [string]$EmbedModel = "embeddinggemma:latest",
    [string]$OllamaUrl = "http://localhost:11434",
    [int]$MaxRetries = 2,
    [switch]$DryRun = $false
)

# Suprimir warnings de JSON depth (normal en responses MCP)
$WarningPreference = "SilentlyContinue"


# ============================================================
# CARGAR MODULOS EXTERNOS
# ============================================================
# Variables globales para permitir cambio dinamico de conexion
$global:McpServerUrl = $McpServerUrl
$global:BearerToken = $BearerToken

Import-Module "$PSScriptRoot\\arg-extractor-v2.psm1" -Force -DisableNameChecking | Out-Null
Import-Module "$PSScriptRoot\\local-validator.psm1" -Force -DisableNameChecking | Out-Null
Load-ToolSchemas -schemaJsonPath "$PSScriptRoot\\tool-schemas.json"

# ============================================================
# CONFIGURACION
# ============================================================
$global:EmbeddingCache = @{}
$global:ToolEmbedCache = @()
$global:N8nApiKey = $(if ($env:N8N_API_KEY) { $env:N8N_API_KEY } else { "YOUR_N8N_API_KEY_HERE" })
$global:N8nDomain = "https://ardf.dev"
$global:HistoryPassword = $null

$ClusterPatterns = @(
    @{ name = "WORKFLOW_BUILD";    pattern = '(?i)\b(create|build|make|write|save\s*new|new|validate|check|verify|sdk|docs|reference)\b.*\b(workflow|code)\b|\b(workflow|code)\b.*\b(create|build|make|new|from\s*code|sdk|validate|check|verify|docs|reference)\b'; tools = @("create_workflow_from_code", "update_workflow", "validate_workflow", "get_sdk_reference") }
    @{ name = "TESTING";           pattern = '(?i)\b(test|mock|simulate|dry\s*run|pin\s*data|preview)\b(?!.*\b(activate|deactivate|unpublish|publish|archive|turn\s*on|turn\s*off)\b).*\b(workflow|execution|node)\b|\b(workflow|execution|node)\b.*\b(test|mock|simulate|dry\s*run|pin\s*data|preview)\b(?!.*\b(activate|deactivate|unpublish|publish|archive|turn\s*on|turn\s*off)\b)'; tools = @("test_workflow", "prepare_test_pin_data") }
    @{ name = "DATA_TABLES";       pattern = '(?i)\bdata\s*table|tables?\b.*\b(create|add|rename|delete|search|list|insert|rows?|column|columns)\b|\b(create|add|rename|delete|search|list|insert)\b.*\b(data\s*table|tables?)\b'; tools = @("search_data_tables", "create_data_table", "rename_data_table", "add_data_table_column", "delete_data_table_column", "rename_data_table_column", "add_data_table_rows") }
    @{ name = "NODES_DISCOVERY";   pattern = '(?i)\b(nodes?|node\b).*\b(find|search|recommend|type|suggest|use|for|which|what)\b|\b(find|search|recommend|suggest)\b.*\b(nodes?|node\b)'; tools = @("search_nodes", "get_node_types", "get_suggested_nodes") }
    @{ name = "WORKFLOW_MGMT";     pattern = '(?i)\b(workflow)\b.*\b(list|search|find|run|execute|activate|turn\s*on|turn\s*off|deactivate|details|describe|archive|delete|remove|get)\b|\b(list|search|find|run|execute|activate|deactivate|archive)\b.*\b(workflow)\b'; tools = @("search_workflows", "get_workflow_details", "execute_workflow", "get_execution", "publish_workflow", "unpublish_workflow", "archive_workflow") }
    @{ name = "PROJECTS";          pattern = '(?i)\b(project|folder|projects|folders)\b'; tools = @("search_projects", "search_folders") }
)

$OptimizedDescriptions = @{
    search_workflows = "[WORKFLOW] SEARCH: Find workflows by name or filter"
    execute_workflow = "[EXECUTION] RUN: Execute a published workflow by ID"
    get_execution = "[EXECUTION] INSPECT: Get execution results by execution ID"
    get_workflow_details = "[WORKFLOW] DESCRIBE: Get full details of a workflow"
    publish_workflow = "[WORKFLOW] ACTIVATE: Enable a workflow for production"
    unpublish_workflow = "[WORKFLOW] DEACTIVATE: Disable a workflow from running"
    prepare_test_pin_data = "[TESTING] MOCK: Generate simulated input data for testing"
    test_workflow = "[TESTING] DRY-RUN: Execute a workflow with simulated data"
    search_data_tables = "[DATA] LIST: Find data tables"
    create_data_table = "[DATA] CREATE: Create a new data table with columns"
    rename_data_table = "[DATA] RENAME: Change the name of a data table"
    add_data_table_column = "[DATA] ADD COLUMN: Add a new column to a data table"
    delete_data_table_column = "[DATA] DELETE COLUMN: Remove a column from a data table"
    rename_data_table_column = "[DATA] RENAME COLUMN: Change a column name"
    add_data_table_rows = "[DATA] INSERT ROWS: Add rows to a data table"
    search_nodes = "[NODES] FIND: Search for available n8n nodes"
    get_node_types = "[NODES] GET TYPES: Get exact parameter names for a node"
    get_suggested_nodes = "[NODES] RECOMMEND: Get node suggestions for a pattern"
    validate_workflow = "[BUILD] CHECK: Validate SDK code for errors"
    create_workflow_from_code = "[BUILD] SAVE NEW: Create workflow from validated SDK code"
    search_projects = "[PROJECTS] LIST: Find projects to get projectId"
    search_folders = "[PROJECTS] LIST FOLDERS: Find folders within a project"
    archive_workflow = "[WORKFLOW] ARCHIVE: Archive a workflow by ID"
    update_workflow = "[BUILD] SAVE EXISTING: Update workflow from validated SDK code"
    get_sdk_reference = "[BUILD] DOCS: Get SDK patterns and syntax rules"
}

# ============================================================
# FUNCIONES DE CONFIGURACION DINAMICA
# ============================================================
function Set-McpToken {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Token
    )
    $global:BearerToken = $Token
    Write-Host "  [config] MCP Bearer Token actualizado correctamente." -ForegroundColor Green
}

function Set-N8nApiKey {
    param(
        [Parameter(Mandatory=$true)]
        [string]$ApiKey
    )
    $global:N8nApiKey = $ApiKey
    Write-Host "  [config] API Key de n8n actualizada correctamente." -ForegroundColor Green
}

function Set-N8nDomain {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Domain
    )
    $cleanDomain = $Domain.Trim()
    if ($cleanDomain -notmatch '^https?://') {
        $cleanDomain = "https://" + $cleanDomain
    }
    if ($cleanDomain.EndsWith("/")) {
        $cleanDomain = $cleanDomain.Substring(0, $cleanDomain.Length - 1)
    }
    $global:N8nDomain = $cleanDomain
    Write-Host "  [config] Dominio de n8n configurado como: $global:N8nDomain" -ForegroundColor Green
}

# ============================================================
# HELPERS MCP / OLLAMA
# ============================================================
function Send-McpRequest($Method, $Params = $null) {
    $body = @{ jsonrpc = "2.0"; id = (Get-Random); method = $Method }
    if ($Params -ne $null) { $body['params'] = $Params }
    $json = $body | ConvertTo-Json -Depth 5 -Compress
    $headers = @{ "Authorization" = "Bearer $global:BearerToken"; "Content-Type" = "application/json"; "Accept" = "application/json, text/event-stream" }
    try {
        $resp = Invoke-RestMethod -Uri $global:McpServerUrl -Method Post -Body $json -Headers $headers -TimeoutSec 20
        $lines = $resp -split "`n"
        foreach ($line in $lines) {
            if ($line -match '^data:\s*(.+)$') {
                $obj = ($matches[1] | ConvertFrom-Json)
                if ($obj.error) { Write-Warning "MCP Error: $($obj.error.message)"; return $null }
                if ($obj.result) { return $obj.result }
            }
        }
        return $null
    } catch { Write-Warning "Connection: $_"; return $null }
}

function Get-Embedding($text) {
    $cacheKey = $text.ToLower()
    if ($global:EmbeddingCache.ContainsKey($cacheKey)) { return $global:EmbeddingCache[$cacheKey] }
    $body = @{ model = $EmbedModel; input = $text } | ConvertTo-Json -Compress
    try {
        $resp = Invoke-RestMethod -Uri "$OllamaUrl/api/embed" -Method Post -Body $body -ContentType "application/json" -TimeoutSec 30
        if ($resp.embeddings -and $resp.embeddings.Count -gt 0) {
            $global:EmbeddingCache[$cacheKey] = $resp.embeddings[0]
            return $resp.embeddings[0]
        }
    } catch { Write-Warning "Embedding error: $_" }
    return $null
}

function Cosine-Similarity($a, $b) {
    $dot = 0.0; $normA = 0.0; $normB = 0.0
    for ($i = 0; $i -lt $a.Count; $i++) { $dot += $a[$i] * $b[$i]; $normA += $a[$i] * $a[$i]; $normB += $b[$i] * $b[$i] }
    if ($normA -eq 0 -or $normB -eq 0) { return 0.0 }
    [double]($dot / ([Math]::Sqrt($normA) * [Math]::Sqrt($normB)))
}

function Send-ChatMessage($Messages, $Model, $Tools = @(), $MaxTokens = 200) {
    $body = @{ model = $Model; messages = $Messages; tools = $Tools; stream = $false; options = @{ num_predict = $MaxTokens; temperature = 0.05 } } | ConvertTo-Json -Depth 10 -Compress
    try { Invoke-RestMethod -Uri "$OllamaUrl/api/chat" -Method Post -Body $body -ContentType "application/json" -TimeoutSec 60 }
    catch { Write-Warning "Ollama: $_"; $null }
}

function Convert-ToolToOllama($tool) {
    $cleanProps = @{}
    if ($tool.inputSchema.properties) {
        foreach ($propName in $tool.inputSchema.properties.PSObject.Properties.Name) {
            $prop = $tool.inputSchema.properties.$propName
            $entry = @{ type = $prop.type }
            if ($prop.enum) { $entry['enum'] = $prop.enum }
            $cleanProps[$propName] = $entry
        }
    }
    @{ type = "function"; function = @{ name = $tool.name; description = $tool.description; parameters = @{ type = "object"; properties = $cleanProps } } }
}

function Get-ClusterByRegex($inputText) {
    foreach ($c in $ClusterPatterns) { if ($inputText -match $c.pattern) { return $c } }
    return $ClusterPatterns | Where-Object { $_.name -eq "WORKFLOW_MGMT" } | Select-Object -First 1
}

function Test-ValidToolCall($response, $selectedToolNames) {
    if (-not $response -or -not $response.message) { return @{ valid = $false; reason = "No response" } }
    $msg = $response.message
    if (-not $msg.tool_calls -or $msg.tool_calls.Count -eq 0) { return @{ valid = $false; reason = "No tool call made" } }
    $tc = $msg.tool_calls[0]
    $toolName = $tc.function.name
    if ($selectedToolNames -notcontains $toolName) { return @{ valid = $false; reason = "Tool '$toolName' not in selected set" } }
    @{ valid = $true; toolCall = $tc }
}

function Get-FallbackTool($cluster, $queryLower) {
    $keywords = @{
        'search_workflows' = @('list','all','show','find','search','my workflows')
        'get_workflow_details' = @('details','describe','info','about','what is')
        'execute_workflow' = @('run','execute','trigger','start','fire')
        'publish_workflow' = @('activate','turn on','enable')
        'unpublish_workflow' = @('deactivate','turn off','disable')
        'archive_workflow' = @('archive','delete','remove')
        'get_sdk_reference' = @('sdk','reference','docs','documentation','help')
        'validate_workflow' = @('validate','check','verify','test code')
        'create_workflow_from_code' = @('build','create','make','new','write')
        'search_nodes' = @('find nodes','search nodes','node for','integration')
        'search_projects' = @('projects','folders')
        'search_data_tables' = @('data table','tables')
    }
    foreach ($toolName in $cluster.tools) {
        if ($keywords.ContainsKey($toolName)) {
            foreach ($kw in $keywords[$toolName]) {
                if ($queryLower.Contains($kw)) { return $toolName }
            }
        }
    }
    return $cluster.tools[0]
}

function Show-Logo($toolCount) {
    Write-Host ""
    Write-Host "    +======================================================+" -ForegroundColor Cyan
    Write-Host "    |  n8n MCP CLIENT - Auto-Correction Pipeline v2.0      |" -ForegroundColor Cyan
    Write-Host "    |  Regex cluster -> Embeddings (cache) -> qwen2.5:0.5b |" -ForegroundColor Cyan
    Write-Host "    |  + Guardrails + Strict Schema Validator + Retry (2)  |" -ForegroundColor Cyan
    Write-Host "    +======================================================+" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "    Herramientas: $toolCount en $($ClusterPatterns.Count) clusters" -ForegroundColor Gray
    Write-Host "    DryRun: $DryRun | Escribe 'salir' o 'exit' para terminar." -ForegroundColor Gray
    Write-Host ""
}

function Get-WorkflowMap() {
    $wfResult = Send-McpRequest -Method "tools/call" -Params @{ name = "search_workflows"; arguments = @{ limit = 50 } }
    $map = @{}
    if ($wfResult -and $wfResult.content) {
        $text = ($wfResult.content | Where-Object { $_.type -eq "text" } | Select-Object -ExpandProperty text) -join ""
        try {
            $parsed = $text | ConvertFrom-Json
            foreach ($w in $parsed.data) { $map[$w.name.ToLower()] = $w.id }
        } catch {}
    }
    $map
}

function Invoke-HistoryDbCommand($Cmd, $CmdArgs = @()) {
    $nodePath = "$PSScriptRoot\n8n-validator\execution-cache.js"
    $fullArgs = @()
    
    if ($global:HistoryPassword) {
        $fullArgs += "secure"
        $fullArgs += $global:HistoryPassword
    }
    
    $fullArgs += $Cmd
    if ($CmdArgs) {
        foreach ($arg in $CmdArgs) { $fullArgs += $arg }
    }
    
    $output = & node $nodePath $fullArgs 2>&1
    $jsonText = ($output -join "`n").Trim()
    
    try {
        $result = $jsonText | ConvertFrom-Json
        return $result
    } catch {
        if ($jsonText -match "Password incorrecto|descifrar") {
            return @{ success = $false; error = "Password incorrecto: Error al descifrar la base de datos." }
        }
        return @{ success = $false; error = "Error al parsear respuesta local: $jsonText" }
    }
}

function Show-HistoryResult($Type, $Result) {
    if (-not $Result -or $Result.success -eq $false) {
        $msg = if ($Result.error) { $Result.error } else { "Error desconocido al acceder a la base de datos local." }
        Write-Host "  [!] ERROR: $msg" -ForegroundColor Red
        if ($msg -match "Password incorrecto|descifrar") {
            Write-Host "  HINT: Usa '/history -secure <password>' para desbloquear la base de datos." -ForegroundColor Yellow
        }
        return
    }
    
    if ($Type -eq "list" -or $Type -eq "filter") {
        $data = $Result.data
        if (-not $data -or $data.Count -eq 0) {
            Write-Host "  No se encontraron ejecuciones en la base de datos local." -ForegroundColor Yellow
            return
        }
        
        Write-Host ""
        Write-Host "  +========================================================================================================+" -ForegroundColor Cyan
        Write-Host "  |                                        HISTORIAL DE EJECUCIONES                                        |" -ForegroundColor Cyan
        Write-Host "  +========================================================================================================+" -ForegroundColor Cyan
        Write-Host "  | ID               | Workflow                      | Status     | Modo     | Started At           | Dur. |" -ForegroundColor Cyan
        Write-Host "  +==================+===============================+============+==========+======================+======+" -ForegroundColor Cyan
        
        foreach ($ex in $data) {
            $id = $ex.id.ToString().PadRight(16).Substring(0, 16)
            
            $wfName = "Workflow Desconocido"
            if ($ex.workflow -and $ex.workflow.name) {
                $wfName = $ex.workflow.name
            } elseif ($ex.workflowName) {
                $wfName = $ex.workflowName
            }
            $wf = $wfName.PadRight(29).Substring(0, 29)
            
            $status = $ex.status.PadRight(10).Substring(0, 10)
            $mode = $ex.mode.PadRight(8).Substring(0, 8)
            $started = $ex.startedAt.ToString().PadRight(20).Substring(0, 20)
            
            $dur = "$($ex.durationSeconds)s"
            $durPad = $dur.PadRight(4).Substring(0, 4)
            
            Write-Host "  | " -NoNewline -ForegroundColor Cyan
            Write-Host "$id" -NoNewline -ForegroundColor White
            Write-Host " | " -NoNewline -ForegroundColor Cyan
            Write-Host "$wf" -NoNewline -ForegroundColor White
            Write-Host " | " -NoNewline -ForegroundColor Cyan
            
            if ($ex.status -eq "success") {
                Write-Host "$status" -NoNewline -ForegroundColor Green
            } elseif ($ex.status -eq "failed") {
                Write-Host "$status" -NoNewline -ForegroundColor Red
            } else {
                Write-Host "$status" -NoNewline -ForegroundColor Yellow
            }
            
            Write-Host " | " -NoNewline -ForegroundColor Cyan
            Write-Host "$mode" -NoNewline -ForegroundColor White
            Write-Host " | " -NoNewline -ForegroundColor Cyan
            Write-Host "$started" -NoNewline -ForegroundColor White
            Write-Host " | " -NoNewline -ForegroundColor Cyan
            Write-Host "$durPad" -NoNewline -ForegroundColor White
            Write-Host " |" -ForegroundColor Cyan
        }
        Write-Host "  +==================+===============================+============+==========+======================+======+" -ForegroundColor Cyan
        Write-Host "  Total: $($Result.count) ejecuciones" -ForegroundColor DarkGray
        return
    }
    
    if ($Type -eq "stats") {
        $data = $Result.data
        if (-not $data -or $data.Count -eq 0) {
            Write-Host "  No hay estadísticas disponibles. Sincroniza primero usando '/history -sync'." -ForegroundColor Yellow
            return
        }
        
        Write-Host ""
        Write-Host "  +=========================================================================================+" -ForegroundColor Cyan
        Write-Host "  |                                ESTADÍSTICAS DE WORKFLOWS                                |" -ForegroundColor Cyan
        Write-Host "  +=========================================================================================+" -ForegroundColor Cyan
        Write-Host "  | Workflow Name                 | Total Runs | Success % | Failed %  | Avg Duration (s) |" -ForegroundColor Cyan
        Write-Host "  +===============================+============+===========+===========+==================+" -ForegroundColor Cyan
        
        foreach ($stat in $data) {
            $name = "Workflow Desconocido"
            if ($stat.workflowName) {
                $name = $stat.workflowName
            }
            $wf = $name.PadRight(29).Substring(0, 29)
            
            $runs = $stat.totalRuns.ToString().PadRight(10).Substring(0, 10)
            
            $sucRate = "0.0%"
            $failRate = "0.0%"
            if ($stat.totalRuns -gt 0) {
                $sucRate = "$([Math]::Round(($stat.successCount / $stat.totalRuns) * 100, 1))%"
                $failRate = "$([Math]::Round(($stat.failedCount / $stat.totalRuns) * 100, 1))%"
            }
            $suc = $sucRate.PadRight(9).Substring(0, 9)
            $fail = $failRate.PadRight(9).Substring(0, 9)
            
            $avgDur = "$([Math]::Round($stat.avgDurationSeconds, 1))s"
            $avg = $avgDur.PadRight(16).Substring(0, 16)
            
            Write-Host "  | " -NoNewline -ForegroundColor Cyan
            Write-Host "$wf" -NoNewline -ForegroundColor White
            Write-Host " | " -NoNewline -ForegroundColor Cyan
            Write-Host "$runs" -NoNewline -ForegroundColor White
            Write-Host " | " -NoNewline -ForegroundColor Cyan
            Write-Host "$suc" -NoNewline -ForegroundColor Green
            Write-Host " | " -NoNewline -ForegroundColor Cyan
            Write-Host "$fail" -NoNewline -ForegroundColor Red
            Write-Host " | " -NoNewline -ForegroundColor Cyan
            Write-Host "$avg" -NoNewline -ForegroundColor White
            Write-Host " |" -ForegroundColor Cyan
        }
        Write-Host "  +===============================+============+===========+===========+==================+" -ForegroundColor Cyan
        return
    }
}

# ============================================================
# LOOP INTERACTIVO
# ============================================================
function Invoke-CreateWorkflowWithValidation() {
    Write-Host "  [builder] Generando workflow desde template..." -ForegroundColor DarkGray
    $nodePath = "$PSScriptRoot\n8n-validator\workflow-builder.js"
    $templatesPath = "$PSScriptRoot\workflow-templates.json"
    $output = node $nodePath "$templatesPath" "$global:McpServerUrl" "$global:BearerToken" "$query" 2>&1
    # El output mezcla logs + JSON final. Extraer la ultima linea JSON.
    $lines = $output -split "`r?`n"
    $jsonLine = $null
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        if ($lines[$i].Trim().StartsWith('{')) { $jsonLine = $lines[$i].Trim(); break }
    }
    if (-not $jsonLine) {
        Write-Host "  [builder] No se pudo generar workflow" -ForegroundColor Red
        return $null
    }
    $result = $jsonLine | ConvertFrom-Json
    if ($result.error) {
        Write-Host "  [builder] Error: $($result.error)" -ForegroundColor Red
        if ($result.hint) { Write-Host "  HINT: $($result.hint)" -ForegroundColor Yellow }
        return $null
    }
    if ($result.success) {
        $mcpParsed = $result.mcpResponse | ConvertFrom-Json
        Write-Host ""
        Write-Host "  OK WORKFLOW CREADO EXITOSAMENTE" -ForegroundColor Green
        Write-Host "  ID: ID:       $($mcpParsed.workflowId)" -ForegroundColor White
        Write-Host "  Name: Nombre:   $($mcpParsed.name)" -ForegroundColor White
        Write-Host "  Status: Nodos:    $($mcpParsed.nodeCount)" -ForegroundColor White
        Write-Host "  Connections: URL:      $($mcpParsed.url)" -ForegroundColor White
        if ($result.requiresCredentials) {
            Write-Host ""
            Write-Host "  WARNING:  CREDENCIALES REQUERIDAS:" -ForegroundColor Yellow
            foreach ($cn in $result.credentialNodes) {
                Write-Host "     * $($cn.name) ($($cn.type))" -ForegroundColor Yellow
            }
            Write-Host ""
            Write-Host "  HINT: Configura las credenciales en n8n antes de activar este workflow." -ForegroundColor Cyan
        }
        return $mcpParsed
    }
    return $null
}
function Invoke-McpAgentLoop {
    Write-Host "[n8n] Conectando..." -ForegroundColor DarkGray
    $init = Send-McpRequest -Method "initialize" -Params @{
        protocolVersion = "2024-11-05"
        capabilities    = @{}
        clientInfo      = @{ name = "auto-correct-client-v2"; version = "2.0.0" }
    }
    if (-not $init) { return }
    Write-Host "[n8n] Servidor: $($init.serverInfo.name) v$($init.serverInfo.version)" -ForegroundColor Green

    $toolsList = Send-McpRequest -Method "tools/list"
    if (-not $toolsList -or -not $toolsList.tools) { Write-Host "[n8n] Sin herramientas." -ForegroundColor Red; return }

    $allTools = $toolsList.tools
    $optimizedTools = @()
    foreach ($tool in $allTools) {
        $optDesc = if ($OptimizedDescriptions.ContainsKey($tool.name)) { $OptimizedDescriptions[$tool.name] } else { $tool.description }
        $newTool = $tool | ConvertTo-Json -Depth 5 | ConvertFrom-Json
        $newTool.description = $optDesc
        $optimizedTools += $newTool
    }

    Write-Host "[embed] Indexando $($optimizedTools.Count) herramientas..." -ForegroundColor DarkGray
    if ($global:ToolEmbedCache.Count -eq 0) {
        $toolsJson = $optimizedTools | ConvertTo-Json -Depth 10 -Compress
        $tempToolsFile = [System.IO.Path]::GetTempFileName()
        Set-Content -Path $tempToolsFile -Value $toolsJson -Encoding UTF8
        try {
            $nodePath = Join-Path $PSScriptRoot "n8n-validator\get-tool-embeddings.js"
            $respLines = & node $nodePath $tempToolsFile 2>&1
            $jsonLine = $null
            foreach ($line in $respLines) {
                $trimmed = $line.ToString().Trim()
                if ($trimmed.StartsWith("[") -and $trimmed.EndsWith("]")) {
                    try {
                        $test = $trimmed | ConvertFrom-Json
                        if ($test) {
                            $jsonLine = $trimmed
                            break
                        }
                    } catch {}
                }
            }
            if ($jsonLine) {
                $parsedEmbeds = $jsonLine | ConvertFrom-Json
                foreach ($item in $parsedEmbeds) {
                    $global:ToolEmbedCache += [PSCustomObject]@{
                        name = $item.name
                        tool = $item.tool
                        embedding = $item.embedding
                    }
                }
            } else {
                Write-Warning "No se pudo encontrar el array JSON de herramientas en la salida de Node: $respLines"
            }
        } finally {
            if (Test-Path $tempToolsFile) { Remove-Item $tempToolsFile -Force }
        }
    }
    Write-Host "[embed] $($global:ToolEmbedCache.Count) tools indexadas (cache)" -ForegroundColor Green

    $wfMap = Get-WorkflowMap
    Write-Host "[n8n] $($wfMap.Count) workflows mapeados por nombre" -ForegroundColor Green

    Show-Logo -toolCount $allTools.Count

    while ($true) {
        Write-Host "[usuario] " -NoNewline -ForegroundColor Green
        $inputText = Read-Host
        if ($inputText -match '^(salir|exit|quit)$') { break }
        if ([string]::IsNullOrWhiteSpace($inputText)) { continue }

        $queryLower = $inputText.ToLower()

        # COMANDOS ESPECIALES
        if ($inputText -match '^/help') {
            Write-Host "
  Comandos disponibles:" -ForegroundColor Cyan
            Write-Host "    /connect <url> <token>  - Cambiar URL y token del MCP" -ForegroundColor White
            Write-Host "    /token <token>          - Cambiar solo el Bearer token del MCP" -ForegroundColor White
            Write-Host "    /mcp-token <token>      - Cambiar solo el Bearer token del MCP" -ForegroundColor White
            Write-Host "    /apikey <key>           - Definir la API Key de n8n" -ForegroundColor White
            Write-Host "    /n8n-apikey <key>       - Definir la API Key de n8n" -ForegroundColor White
            Write-Host "    /domain <url>           - Definir el dominio base de n8n (ej. ardf.dev)" -ForegroundColor White
            Write-Host "    /n8n-domain <url>       - Definir el dominio base de n8n" -ForegroundColor White
            Write-Host "    /url <url>              - Cambiar solo la URL del servidor MCP" -ForegroundColor White
            Write-Host "    /status                 - Mostrar configuracion actual" -ForegroundColor White
            Write-Host "    /history -sync [<key>]  - Sincroniza ejecuciones y workflows de n8n" -ForegroundColor White
            Write-Host "    /history -list [<limit>]- Lista las ejecuciones almacenadas localmente" -ForegroundColor White
            Write-Host "    /history -stats         - Muestra métricas agregadas por workflow" -ForegroundColor White
            Write-Host "    /history -filter <f> <v>- Filtra ejecuciones (ej. status failed)" -ForegroundColor White
            Write-Host "    /history -secure [<pw>] - Activa cifrado AES-256-GCM en la base de datos" -ForegroundColor White
            Write-Host "    /help                   - Mostrar esta ayuda" -ForegroundColor White
            Write-Host "    salir | exit | quit     - Terminar el cliente" -ForegroundColor White
            Write-Host ""
            continue
        }
        if ($inputText -match '^/connect\s+(\S+)\s+(.+)') {
            $global:McpServerUrl = $matches[1]
            Set-McpToken -Token $matches[2]
            # Recargar workflows de la nueva instancia
            $wfMap = Get-WorkflowMap
            Write-Host "  [config] Conexion exitosa. $($wfMap.Count) workflows mapeados." -ForegroundColor Green
            continue
        }
        if ($inputText -match '^/(?:token|mcp-token)\s+(.+)') {
            Set-McpToken -Token $matches[1]
            continue
        }
        if ($inputText -match '^/(?:apikey|n8n-apikey)\s+(.+)') {
            Set-N8nApiKey -ApiKey $matches[1]
            continue
        }
        if ($inputText -match '^/(?:domain|n8n-domain)\s+(.+)') {
            Set-N8nDomain -Domain $matches[1]
            continue
        }
        if ($inputText -match '^/url\s+(\S+)') {
            $global:McpServerUrl = $matches[1]
            Write-Host "  [config] URL de servidor MCP actualizada a $global:McpServerUrl" -ForegroundColor Cyan
            continue
        }
        if ($inputText -match '^/status') {
            $mcpTokenMasked = if ($global:BearerToken -and $global:BearerToken.Length -gt 15) {
                $global:BearerToken.Substring(0, 10) + "..." + $global:BearerToken.Substring($global:BearerToken.Length - 10)
            } else {
                "No configurado"
            }
            
            $apiKeyMasked = if ($global:N8nApiKey -and $global:N8nApiKey.Length -gt 15) {
                $global:N8nApiKey.Substring(0, 10) + "..." + $global:N8nApiKey.Substring($global:N8nApiKey.Length - 10)
            } else {
                "No configurada"
            }
            
            Write-Host "
  Configuración actual:" -ForegroundColor Cyan
            Write-Host "    MCP Server URL:  $global:McpServerUrl" -ForegroundColor White
            Write-Host "    MCP Token:       $mcpTokenMasked" -ForegroundColor White
            Write-Host "    n8n API Key:     $apiKeyMasked" -ForegroundColor White
            Write-Host "    n8n Domain:      $(if ($global:N8nDomain) { $global:N8nDomain } else { 'No configurado (derivado de MCP)' })" -ForegroundColor White
            Write-Host "    Modelo Router:   $RouterModel" -ForegroundColor White
            Write-Host "    DryRun Mode:     $DryRun" -ForegroundColor White
            Write-Host ""
            continue
        }
        if ($inputText -match '^/history(?:\s+(.*))?') {
            $historyArgs = $matches[1]
            
            if ([string]::IsNullOrWhiteSpace($historyArgs)) {
                $historyArgs = "-list"
            }
            
            if ($historyArgs -match '^-sync(?:\s+(\S+))?') {
                $syncKey = $matches[1]
                if (-not $syncKey) {
                    if ($env:N8N_API_KEY) {
                        $syncKey = $env:N8N_API_KEY
                    } elseif ($global:N8nApiKey) {
                        $syncKey = $global:N8nApiKey
                    }
                }
                
                if (-not $syncKey) {
                    Write-Host "  [!] ERROR: Se requiere una API Key para sincronizar con n8n." -ForegroundColor Red
                    Write-Host "  HINT: Pásala directamente: '/history -sync TU_API_KEY' o configúrala en `$env:N8N_API_KEY`." -ForegroundColor Yellow
                    continue
                }
                
                Write-Host "  [history] Sincronizando historial de ejecuciones y workflows..." -ForegroundColor Cyan
                $baseUrl = $global:N8nDomain
                if (-not $baseUrl) {
                    if ($global:McpServerUrl -match '^(https?://[^/]+)') {
                        $baseUrl = $matches[1]
                    } else {
                        $baseUrl = "https://ardf.dev"
                    }
                }
                
                $res = Invoke-HistoryDbCommand -Cmd "sync" -CmdArgs @($syncKey, $baseUrl)
                if ($res -and $res.success) {
                    Write-Host "  [OK] Sincronización incremental completada exitosamente." -ForegroundColor Green
                } else {
                    $errMsg = if ($res -and $res.error) { $res.error } else { "Error de conexión o credenciales" }
                    Write-Host "  [FAIL] Sincronización fallida: $errMsg" -ForegroundColor Red
                }
                continue
            }
            
            if ($historyArgs -match '^-list(?:\s+(\d+))?') {
                $limit = $matches[1]
                if (-not $limit) { $limit = "20" }
                
                $res = Invoke-HistoryDbCommand -Cmd "list" -CmdArgs @($limit)
                Show-HistoryResult -Type "list" -Result $res
                continue
            }
            
            if ($historyArgs -match '^-stats') {
                $res = Invoke-HistoryDbCommand -Cmd "stats"
                Show-HistoryResult -Type "stats" -Result $res
                continue
            }
            
            if ($historyArgs -match '^-filter\s+(\S+)\s+(.+)') {
                $field = $matches[1]
                $val = $matches[2]
                
                $limit = "20"
                if ($val -match '^(.+)\s+(\d+)$') {
                    $val = $matches[1].Trim()
                    $limit = $matches[2]
                }
                
                $res = Invoke-HistoryDbCommand -Cmd "filter" -CmdArgs @($field, $val, $limit)
                Show-HistoryResult -Type "filter" -Result $res
                continue
            }
            
            if ($historyArgs -match '^-secure(?:\s+(.+))?') {
                $pw = $matches[1]
                if (-not $pw) {
                    Write-Host "Introduce la contraseña maestra para cifrar/descifrar la base de datos:" -ForegroundColor Cyan
                    $securePw = Read-Host -AsSecureString
                    $pw = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePw))
                }
                
                if ([string]::IsNullOrWhiteSpace($pw)) {
                    Write-Host "  [!] Contraseña inválida o vacía." -ForegroundColor Red
                    continue
                }
                
                $oldPw = $global:HistoryPassword
                $global:HistoryPassword = $pw
                
                Write-Host "  [history] Verificando contraseña y cargando base de datos..." -ForegroundColor Cyan
                $res = Invoke-HistoryDbCommand -Cmd "stats"
                
                if ($res -and $res.success) {
                    Write-Host "  [OK] Contraseña correcta. Base de datos cargada y activa." -ForegroundColor Green
                } else {
                    $global:HistoryPassword = $oldPw
                    if ($res -and $res.error -match "Password incorrecto") {
                        Write-Host "  [FAIL] La contraseña proporcionada es incorrecta." -ForegroundColor Red
                    } else {
                        Write-Host "  [FAIL] Error al intentar descifrar la base de datos: $($res.error)" -ForegroundColor Red
                    }
                }
                continue
            }
            
            Write-Host "  Uso de /history:" -ForegroundColor Cyan
            Write-Host "    /history -sync [<key>]  - Sincroniza ejecuciones y workflows de n8n" -ForegroundColor White
            Write-Host "    /history -list [<limit>]- Lista las ejecuciones almacenadas localmente" -ForegroundColor White
            Write-Host "    /history -stats         - Muestra métricas agregadas por workflow" -ForegroundColor White
            Write-Host "    /history -filter <f> <v>- Filtra ejecuciones (ej. status failed)" -ForegroundColor White
            Write-Host "    /history -secure [<pw>] - Activa cifrado AES-256-GCM en la base de datos" -ForegroundColor White
            continue
        }

        # STEP 1: REGEX CLUSTER
        $cluster = Get-ClusterByRegex -inputText $inputText
        Write-Host "  [cluster] $($cluster.name)" -ForegroundColor DarkGray

        # STEP 2: EMBEDDINGS TOP-N
        $queryEmb = Get-Embedding -text $inputText
        $clusterToolEmbeddings = $global:ToolEmbedCache | Where-Object { $cluster.tools -contains $_.name }
        if (($queryLower.Contains('sdk') -or $queryLower.Contains('reference') -or $queryLower.Contains('docs')) -and ($cluster.tools -notcontains 'get_sdk_reference')) {
            $sdkTool = $global:ToolEmbedCache | Where-Object { $_.name -eq 'get_sdk_reference' } | Select-Object -First 1
            if ($sdkTool) { $clusterToolEmbeddings += $sdkTool }
        }

        $scores = @()
        foreach ($te in $clusterToolEmbeddings) {
            $sim = Cosine-Similarity -a $queryEmb -b $te.embedding
            $scores += [PSCustomObject]@{ score = $sim; name = $te.name }
        }
        $topN = ($scores | Sort-Object -Property score -Descending) | Select-Object -First 5
        $selectedToolNames = $topN | ForEach-Object { $_.name }

        $selectedTools = @()
        foreach ($tn in $topN) {
            $toolObj = $global:ToolEmbedCache | Where-Object { $_.name -eq $tn.name } | Select-Object -First 1
            if ($toolObj) { $selectedTools += Convert-ToolToOllama -tool $toolObj.tool }
        }
        Write-Host "  [candidates] $($selectedToolNames -join ', ')" -ForegroundColor DarkGray

        # STEP 3: qwen2.5:0.5b con RETRY / VALIDADOR
        $messages = @(@{ role = "system"; content = "You MUST call one of the available tools. Do NOT answer with text. Call the tool immediately." })
        $messages += @{ role = "user"; content = $inputText }

        $finalToolCall = $null
        $attempt = 0
        while ($attempt -lt $MaxRetries) {
            $attempt++
            Write-Host "  [attempt $attempt/$MaxRetries] Routing..." -ForegroundColor DarkGray
            $response = Send-ChatMessage -Messages $messages -Model $RouterModel -Tools $selectedTools -MaxTokens 120
            $validation = Test-ValidToolCall -response $response -selectedToolNames $selectedToolNames

            if ($validation.valid) {
                $finalToolCall = $validation.toolCall
                Write-Host "  [validator] Tool call valido: $($finalToolCall.function.name)" -ForegroundColor Green
                break
            } else {
                Write-Host "  [validator] INVALIDO: $($validation.reason)" -ForegroundColor Red
                if ($attempt -lt $MaxRetries) {
                    $messages += @{ role = "assistant"; content = "" }
                    $messages += @{ role = "user"; content = "That was incorrect. $($validation.reason). You MUST call one of the available tools. Try again." }
                }
            }
        }

        # Fallback mejorado con heuristica de keywords
        if ($finalToolCall -eq $null -and $cluster.tools.Count -gt 0) {
            $fallbackTool = Get-FallbackTool -cluster $cluster -queryLower $queryLower
            Write-Host "  [fallback] Sin tool call, forzando $($fallbackTool) desde cluster $($cluster.name)" -ForegroundColor Magenta
            $finalToolCall = @{ function = @{ name = $fallbackTool; arguments = @{ } } }
        }

        if ($finalToolCall -eq $null) {
            Write-Host "[agente] No se pudo obtener una tool call valida tras $MaxRetries intentos." -ForegroundColor Red
            continue
        }

        # STEP 3.5: GUARDRAILS SEMANTICOS
        $toolName = $finalToolCall.function.name

        $listKeywords = @('list','all','show','find','search','my workflows')
        $hasListKeyword = $false
        foreach ($kw in $listKeywords) { if ($queryLower.Contains($kw)) { $hasListKeyword = $true; break } }
        if ($hasListKeyword -and ($selectedToolNames -contains 'search_workflows') -and ($toolName -eq 'get_workflow_details' -or $toolName -eq 'get_execution')) {
            Write-Host "  [guardrail] Forzando search_workflows por intencion de listado" -ForegroundColor Magenta
            $toolName = 'search_workflows'
            $finalToolCall = @{ function = @{ name = 'search_workflows'; arguments = @{ } } }
        }
        if (($queryLower.Contains('sdk') -or $queryLower.Contains('reference') -or $queryLower.Contains('docs')) -and ($selectedToolNames -contains 'get_sdk_reference') -and ($toolName -ne 'get_sdk_reference')) {
            Write-Host "  [guardrail] Forzando get_sdk_reference por intencion de documentacion" -ForegroundColor Magenta
            $toolName = 'get_sdk_reference'
            $finalToolCall = @{ function = @{ name = 'get_sdk_reference'; arguments = @{ section = if ($queryLower.Contains('expression')) { 'expressions' } else { $null } } } }
        }
        if ($queryLower.Contains('validate') -and $queryLower.Contains('code') -and ($selectedToolNames -contains 'validate_workflow') -and ($toolName -ne 'validate_workflow')) {
            Write-Host "  [guardrail] Forzando validate_workflow por intencion de validacion" -ForegroundColor Magenta
            $toolName = 'validate_workflow'
            $finalToolCall = @{ function = @{ name = 'validate_workflow'; arguments = @{ code = '' } } }
        }
        if (($queryLower.Contains('build') -or $queryLower.Contains('create') -or $queryLower.Contains('make') -or $queryLower.Contains('new')) -and -not $queryLower.Contains('update') -and -not $queryLower.Contains('existing') -and ($selectedToolNames -contains 'create_workflow_from_code') -and ($toolName -ne 'create_workflow_from_code')) {
            Write-Host "  [guardrail] Forzando create_workflow_from_code por intencion de crear nueva" -ForegroundColor Magenta
            $toolName = 'create_workflow_from_code'
            $finalToolCall = @{ function = @{ name = 'create_workflow_from_code'; arguments = @{ } } }
        }
        # PIPELINE V3: Template filling + Local validation + Credential check
        if ($toolName -eq "create_workflow_from_code" -and -not $DryRun) {
            Write-Host "  [pipeline-v3] Usando template filling + validacion local..." -ForegroundColor Cyan
            $created = Invoke-CreateWorkflowWithValidation -query $inputText
            if ($created) {
                Write-Host "[agente] Hecho." -ForegroundColor Cyan
                continue
            } else {
                Write-Host "  [pipeline-v3] Fallback al flujo estandar..." -ForegroundColor DarkYellow
            }
        }
        if (($queryLower.Contains('project') -or $queryLower.Contains('projects') -or $queryLower.Contains('folder') -or $queryLower.Contains('folders')) -and ($selectedToolNames -contains 'search_projects') -and ($toolName -ne 'search_projects' -and $toolName -ne 'search_folders')) {
            Write-Host "  [guardrail] Forzando search_projects por intencion de proyectos" -ForegroundColor Magenta
            $toolName = 'search_projects'
            $finalToolCall = @{ function = @{ name = 'search_projects'; arguments = @{ } } }
        }
        if (($queryLower.Contains('node') -or $queryLower.Contains('nodes')) -and ($queryLower.Contains('find') -or $queryLower.Contains('search') -or $queryLower.Contains('for') -or $queryLower.Contains('integration') -or $queryLower.Contains('recommend') -or $queryLower.Contains('suggest')) -and ($selectedToolNames -contains 'search_nodes') -and ($toolName -ne 'search_nodes')) {
            Write-Host "  [guardrail] Forzando search_nodes por intencion de buscar nodes" -ForegroundColor Magenta
            $toolName = 'search_nodes'
            $finalToolCall = @{ function = @{ name = 'search_nodes'; arguments = @{ } } }
        }

        # STEP 4: EXTRACTOR DE ARGUMENTOS (v2 con strict schema)
        $rawArgs = if ($finalToolCall) { $finalToolCall.function.arguments } else { $null }
        $filledArgs = Fill-Arguments -toolName $toolName -arguments $rawArgs -inputText $inputText -wfMap $wfMap
        if ($filledArgs['workflowId']) {
            Write-Host "  [resolve] workflowId = $($filledArgs['workflowId'])" -ForegroundColor DarkYellow
        }

                # STEP 4.5: VALIDACION LOCAL DEL SDK (antes de tocar MCP remoto)
        if (($toolName -eq 'create_workflow_from_code' -or $toolName -eq 'validate_workflow') -and $filledArgs['code'] -and $filledArgs['code'] -notmatch '^\s*//\s*TODO') {
            Write-Host "  [sdk-validate] Validando codigo localmente..." -ForegroundColor DarkGray
            $valResult = Invoke-LocalSDKValidation -code $filledArgs['code']
            Show-ValidationReport -result $valResult
            if (-not $valResult.valid) {
                Write-Host "[agente] Codigo invalido. No se envia al servidor remoto." -ForegroundColor Red
                if ($valResult.hint) { Write-Host "  HINT: $($valResult.hint)" -ForegroundColor Yellow }
                continue
            }
            if ($toolName -eq 'validate_workflow') {
                Write-Host "[agente] Validacion local completada. Workflow OK." -ForegroundColor Cyan
                continue
            }
        }

        Write-Host "  -> n8n tool: $toolName" -ForegroundColor Yellow
        Write-Host "  -> Args: $($filledArgs | ConvertTo-Json -Compress)" -ForegroundColor DarkYellow

        if ($DryRun) {
            Write-Host "  [DRY RUN] No se ejecuta." -ForegroundColor DarkGray
            Write-Host "[agente] Hecho (dry run)." -ForegroundColor Cyan
            continue
        }

        $mcpResult = Send-McpRequest -Method "tools/call" -Params @{
            name = $toolName; arguments = $filledArgs
        }
        if ($mcpResult -and $mcpResult.content) {
            $textResult = ($mcpResult.content | Where-Object { $_.type -eq "text" } | Select-Object -ExpandProperty text) -join "`n"
            if (-not $textResult) { $textResult = ($mcpResult.content | ConvertTo-Json -Depth 3) }
        Write-Host "`n  [RESULTADO]" -ForegroundColor Green
        Show-FormattedResult -toolName $toolName -jsonText $textResult
        continue
        } else {
            Write-Host "`n  [ERROR] No response from MCP" -ForegroundColor Red
        }

        Write-Host "[agente] Hecho." -ForegroundColor Cyan
    }
}


# ============================================================
# FORMATO DE RESULTADOS (UI human-readable)
# ============================================================
function Show-FormattedResult($toolName, $jsonText) {
    try { $data = $jsonText | ConvertFrom-Json } catch { $data = $null }
    if (-not $data) {
        Write-Host "  $jsonText" -ForegroundColor White
        return
    }

    # Formato para listas de workflows
    if ($toolName -eq "search_workflows" -and $data.data) {
        Write-Host ""
        Write-Host "  +======================================================================================+" -ForegroundColor Cyan
        Write-Host "  |                         WORKFLOWS DISPONIBLES                                        |" -ForegroundColor Cyan
        Write-Host "  +======================================================================================+" -ForegroundColor Cyan
        Write-Host "  |  #  | Nombre                          | Estado     | ID                  | Fecha     |" -ForegroundColor Cyan
        Write-Host "  +=====+=================================+============+=====================+===========+" -ForegroundColor Cyan
        $idx = 1
        foreach ($wf in $data.data) {
            $status = if ($wf.active) { "OK Activo  " } else { "[ ] Inactivo" }
            $name = $wf.name.PadRight(31).Substring(0, 31)
            $id = $wf.id.PadRight(19).Substring(0, 19)
            $date = if ($wf.updatedAt) { ([datetime]$wf.updatedAt).ToString("yyyy-MM-dd") } else { "N/A" }
            Write-Host "  | $($idx.ToString().PadRight(2).PadLeft(2))  | $name | $status | $id | $date |" -ForegroundColor White
            $idx++
        }
        Write-Host "  +=====+=================================+============+=====================+===========+" -ForegroundColor Cyan
        Write-Host "  Total: $($data.count) workflow(s)" -ForegroundColor DarkGray
        return
    }

    # Formato para detalles de workflow
    if ($toolName -eq "get_workflow_details" -and $data.workflow) {
        $wf = $data.workflow
        $status = if ($wf.active) { "OK Activo" } else { "[ ] Inactivo" }
        Write-Host ""
        Write-Host "  +======================================================================+" -ForegroundColor Cyan
        Write-Host "  |  WORKFLOW DETAILS                                                    |" -ForegroundColor Cyan
        Write-Host "  +======================================================================+" -ForegroundColor Cyan
        Write-Host "  |  Name: Nombre:     $($wf.name)" -ForegroundColor White
        Write-Host "  |  ID: ID:          $($wf.id)" -ForegroundColor White
        Write-Host "  |  Status: Estado:     $status" -ForegroundColor White
        Write-Host "  |  Created:  Creado:     $($wf.createdAt)" -ForegroundColor White
        Write-Host "  |  Updated: Actualizado: $($wf.updatedAt)" -ForegroundColor White
        Write-Host "  |  Connections: Conexiones:  $($wf.connections | ConvertTo-Json -Compress -Depth 2)" -ForegroundColor White
        if ($wf.nodes) {
            Write-Host "  +======================================================================+" -ForegroundColor Cyan
            Write-Host "  |  NODOS ($($wf.nodes.Count)):" -ForegroundColor Cyan
            foreach ($node in $wf.nodes) {
                Write-Host "  |    * $($node.name) [$($node.type)]" -ForegroundColor White
            }
        }
        Write-Host "  +======================================================================+" -ForegroundColor Cyan
        return
    }

    # Formato para proyectos
    if ($toolName -eq "search_projects" -and $data.data) {
        Write-Host ""
        Write-Host "  +======================================================+" -ForegroundColor Cyan
        Write-Host "  |  PROYECTOS                                           |" -ForegroundColor Cyan
        Write-Host "  +======================================================+" -ForegroundColor Cyan
        foreach ($proj in $data.data) {
            Write-Host "  |  [D] $($proj.name) ($($proj.type))" -ForegroundColor White
            Write-Host "  |     ID: $($proj.id)" -ForegroundColor DarkGray
        }
        Write-Host "  +======================================================+" -ForegroundColor Cyan
        return
    }

    # Formato para SDK reference
    if ($toolName -eq "get_sdk_reference") {
        Write-Host ""
        Write-Host "  +======================================================+" -ForegroundColor Cyan
        Write-Host "  |  SDK REFERENCE                                       |" -ForegroundColor Cyan
        Write-Host "  +======================================================+" -ForegroundColor Cyan
        Write-Host "  |" -ForegroundColor Cyan
        $jsonText -split "`n" | ForEach-Object { Write-Host "  |  $_" -ForegroundColor White }
        Write-Host "  |" -ForegroundColor Cyan
        Write-Host "  +======================================================+" -ForegroundColor Cyan
        return
    }

    # Formato para validacion de workflow
    if ($toolName -eq "validate_workflow") {
        Write-Host ""
        if ($data.valid) {
            Write-Host "  OK Workflow valido!" -ForegroundColor Green
        } else {
            Write-Host "  FAIL Errores de validacion:" -ForegroundColor Red
            foreach ($err in $data.errors) { Write-Host "     * $err" -ForegroundColor Red }
            if ($data.hint) { Write-Host "  HINT: Hint: $($data.hint)" -ForegroundColor Yellow }
        }
        return
    }

    # Formato para busqueda de nodos
    if ($toolName -eq "search_nodes") {
        Write-Host ""
        if ($jsonText -match "No nodes found") {
            Write-Host "  Search: No se encontraron nodos para la busqueda." -ForegroundColor Yellow
        } else {
            Write-Host "  Search: Resultados:" -ForegroundColor Cyan
            $jsonText -split "`n" | ForEach-Object { Write-Host "     $_" -ForegroundColor White }
        }
        return
    }

    # Formato para creacion de workflow
    if ($toolName -eq "create_workflow_from_code") {
        Write-Host ""
        if ($data.workflowId) {
            Write-Host "  +======================================================+" -ForegroundColor Cyan
            Write-Host "  |  WORKFLOW CREADO EXITOSAMENTE                        |" -ForegroundColor Cyan
            Write-Host "  +======================================================+" -ForegroundColor Cyan
            Write-Host "  |  ID: ID:       $($data.workflowId)" -ForegroundColor White
            Write-Host "  |  Name: Nombre:   $($data.name)" -ForegroundColor White
            Write-Host "  |  Connections: URL:      $($data.url)" -ForegroundColor White
            Write-Host "  |  Status: Nodos:    $($data.nodeCount)" -ForegroundColor White
            Write-Host "  +======================================================+" -ForegroundColor Cyan
        } else {
            Write-Host "  FAIL No se pudo crear el workflow." -ForegroundColor Red
        }
        return
    }

    # Fallback generico para cualquier otro resultado
    Write-Host ""
    Write-Host "  +======================================================+" -ForegroundColor Cyan
    Write-Host "  |  RESULTADO                                           |" -ForegroundColor Cyan
    Write-Host "  +======================================================+" -ForegroundColor Cyan
    $jsonText -split "`n" | ForEach-Object { Write-Host "  |  $_" -ForegroundColor White }
    Write-Host "  +======================================================+" -ForegroundColor Cyan
}

Invoke-McpAgentLoop









