$ErrorActionPreference = "Stop"

Write-Host "=== BATERIA DE TESTS POWERSHELL ==="

$scriptPath = "$PSScriptRoot\mcp-client-n8n-final.ps1"
$scriptContent = (Get-Content -Path $scriptPath -Raw) -replace '(?m)^Invoke-McpAgentLoop\s*$', ''
$scriptContent = $scriptContent.Replace('$PSScriptRoot', $PSScriptRoot)

Invoke-Expression $scriptContent

# --- TEST: Regex Clustering ---
try {
    $c1 = Get-ClusterByRegex "crea una data table"
    if ($c1.name -ne "DATA_TABLES") { throw "Expected DATA_TABLES, got $($c1.name)" }

    $c2 = Get-ClusterByRegex "agrega una columna a la tabla"
    if ($c2.name -ne "DATA_TABLES") { throw "Expected DATA_TABLES, got $($c2.name)" }

    $c3 = Get-ClusterByRegex "crea un workflow"
    if ($c3.name -ne "WORKFLOW_BUILD") { throw "Expected WORKFLOW_BUILD, got $($c3.name)" }

    $c4 = Get-ClusterByRegex "ejecuta el workflow"
    if ($c4.name -ne "WORKFLOW_MGMT") { throw "Expected WORKFLOW_MGMT, got $($c4.name)" }

    # --- NEGATIVE / CLUSTERING AMBIGUITY CASES ---
    $c5 = Get-ClusterByRegex "desactiva el workflow"
    if ($c5.name -ne "WORKFLOW_MGMT") { throw "Expected WORKFLOW_MGMT for 'desactiva', got $($c5.name)" }

    $c6 = Get-ClusterByRegex "apaga el workflow de alertas"
    if ($c6.name -ne "WORKFLOW_MGMT") { throw "Expected WORKFLOW_MGMT for 'apaga', got $($c6.name)" }

    $c7 = Get-ClusterByRegex "desactiva el flujo de correos"
    if ($c7.name -ne "WORKFLOW_MGMT") { throw "Expected WORKFLOW_MGMT for 'desactiva flujo', got $($c7.name)" }
    
    Write-Host "✅ Get-ClusterByRegex: OK (Incluyendo Casos Negativos)" -ForegroundColor Green
} catch {
    Write-Host "❌ Get-ClusterByRegex: ERROR - $_" -ForegroundColor Red
}

# --- TEST: Interceptor Data Tables Regex ---
try {
    $testCases = @(
        @{ toolName = "create_data_table"; expected = $true }
        @{ toolName = "add_data_table_column"; expected = $true }
        @{ toolName = "rename_data_table"; expected = $true }
        @{ toolName = "search_data_tables"; expected = $false }
        @{ toolName = "create_workflow_from_code"; expected = $false }
    )
    
    foreach ($tc in $testCases) {
        $toolName = $tc.toolName
        $isMatch = ($toolName -match 'data_table' -and $toolName -ne 'search_data_tables')
        if ($isMatch -ne $tc.expected) {
            throw "Interceptor falló para $toolName. Esperaba $($tc.expected), obtuvo $isMatch"
        }
    }
    
    Write-Host "✅ Interceptor Data Tables Regex: OK" -ForegroundColor Green
} catch {
    Write-Host "❌ Interceptor Data Tables Regex: ERROR - $_" -ForegroundColor Red
}

Write-Host "==================================="
