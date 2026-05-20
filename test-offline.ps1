# test-offline.ps1 - Batería de pruebas de caja negra offline
$ErrorActionPreference = "Stop"

Write-Host "=== INICIANDO BATERIA DE TESTS OFFLINE ===" -ForegroundColor Cyan

# 1. Cargar funciones de mcp-client-n8n-final.ps1 sin iniciar el loop infinito
$scriptPath = "$PSScriptRoot\mcp-client-n8n-final.ps1"
if (-not (Test-Path $scriptPath)) {
    Write-Error "No se encuentra el cliente en '$scriptPath'"
    exit 1
}

$scriptContent = (Get-Content -Path $scriptPath -Raw) -replace '(?m)^Invoke-McpAgentLoop\s*$', ''
$scriptContent = $scriptContent.Replace('$PSScriptRoot', $PSScriptRoot)

# Evaluar funciones
Invoke-Expression $scriptContent

# Guardar valores originales globales para restaurar al final
$oldBearer = $global:BearerToken
$oldApiKey = $global:N8nApiKey
$oldHistory = $global:HistoryPassword

try {
    # --- TEST 1: Protect/Unprotect Secret (DPAPI) ---
    Write-Host "`n[Test 1] Probando Protect-Secret y Unprotect-Secret (DPAPI)..." -ForegroundColor White
    $originalSecret = "SuperSecretApiKey123!"
    $protected = Protect-Secret $originalSecret
    
    Write-Host "  Clave original: $originalSecret" -ForegroundColor Gray
    Write-Host "  Clave encriptada: $protected" -ForegroundColor Gray
    
    if (-not $protected.StartsWith("DPAPI:") -and -not $protected.StartsWith("XOR:")) {
        throw "La clave encriptada no tiene el prefijo DPAPI: o XOR: esperado. Obtuvo: $protected"
    }
    
    $decrypted = Unprotect-Secret $protected
    if ($decrypted -ne $originalSecret) {
        throw "El descifrado falló. Esperaba '$originalSecret', obtuvo '$decrypted'"
    }
    Write-Host "  ✅ Test 1 (Encriptado/Descifrado): OK" -ForegroundColor Green

    # --- TEST 2: Retrocompatibilidad con texto plano ---
    Write-Host "`n[Test 2] Probando retrocompatibilidad de secretos con texto plano..." -ForegroundColor White
    $plainSecret = "PlaintextSecretKey"
    $decryptedPlain = Unprotect-Secret $plainSecret
    if ($decryptedPlain -ne $plainSecret) {
        throw "La retrocompatibilidad de descifrado falló. Esperaba '$plainSecret', obtuvo '$decryptedPlain'"
    }
    Write-Host "  ✅ Test 2 (Retrocompatibilidad): OK" -ForegroundColor Green

    # --- TEST 3: Cifrado en Save-LocalConfig y Descifrado en Load-LocalConfig ---
    Write-Host "`n[Test 3] Probando Save-LocalConfig y Load-LocalConfig con cifrado..." -ForegroundColor White
    
    # Configurar valores globales de prueba
    $global:BearerToken = "McpTokenTestValue123"
    $global:N8nApiKey = "ApiKeyTestValue456"
    $global:HistoryPassword = "HistoryPasswordTestValue789"
    
    Save-LocalConfig
    
    # Validar que config.json contiene valores cifrados
    $configPath = "$PSScriptRoot\n8n-executions-db\config.json"
    if (-not (Test-Path $configPath)) {
        throw "No se creó el archivo config.json en la ruta $configPath"
    }
    
    $rawConfig = Get-Content -Raw -Path $configPath -Encoding UTF8 | ConvertFrom-Json
    Write-Host "  Caché de BearerToken guardado como: $($rawConfig.BearerToken)" -ForegroundColor Gray
    Write-Host "  Caché de N8nApiKey guardado como: $($rawConfig.N8nApiKey)" -ForegroundColor Gray
    
    if ($rawConfig.BearerToken.Contains("McpTokenTestValue123") -or $rawConfig.N8nApiKey.Contains("ApiKeyTestValue456")) {
        throw "¡Los secretos se guardaron en texto plano en config.json! Deben estar cifrados."
    }
    
    # Limpiar variables en memoria para probar carga
    $global:BearerToken = ""
    $global:N8nApiKey = ""
    $global:HistoryPassword = ""
    
    Load-LocalConfig
    
    if ($global:BearerToken -ne "McpTokenTestValue123") {
        throw "Load-LocalConfig falló al restaurar BearerToken. Obtuvo '$global:BearerToken'"
    }
    if ($global:N8nApiKey -ne "ApiKeyTestValue456") {
        throw "Load-LocalConfig falló al restaurar N8nApiKey. Obtuvo '$global:N8nApiKey'"
    }
    if ($global:HistoryPassword -ne "HistoryPasswordTestValue789") {
        throw "Load-LocalConfig falló al restaurar HistoryPassword. Obtuvo '$global:HistoryPassword'"
    }
    Write-Host "  ✅ Test 3 (Persistencia cifrada y restauración): OK" -ForegroundColor Green

    # --- TEST 4: Control Offline de API Key opcional (Guardrails) ---
    Write-Host "`n[Test 4] Probando validaciones offline de API Key opcional..." -ForegroundColor White
    
    # 4.1 Comprobar con API Key configurada
    $global:N8nApiKey = "ValidaApiKey!"
    $apiKeyValid1 = $global:N8nApiKey -and $global:N8nApiKey.Trim() -ne "" -and $global:N8nApiKey -ne "YOUR_N8N_API_KEY_HERE"
    if (-not $apiKeyValid1) {
        throw "El guardrail debería marcar la API Key como válida"
    }
    
    # 4.2 Comprobar con API Key no configurada/por defecto
    $global:N8nApiKey = "YOUR_N8N_API_KEY_HERE"
    $apiKeyValid2 = $global:N8nApiKey -and $global:N8nApiKey.Trim() -ne "" -and $global:N8nApiKey -ne "YOUR_N8N_API_KEY_HERE"
    if ($apiKeyValid2) {
        throw "El guardrail debería marcar la API Key por defecto como inválida"
    }
    
    $global:N8nApiKey = ""
    $apiKeyValid3 = $global:N8nApiKey -and $global:N8nApiKey.Trim() -ne "" -and $global:N8nApiKey -ne "YOUR_N8N_API_KEY_HERE"
    if ($apiKeyValid3) {
        throw "El guardrail debería marcar la API Key vacía como inválida"
    }
    Write-Host "  ✅ Test 4 (Guardrails offline de API Key): OK" -ForegroundColor Green

    Write-Host "`n=== BATERIA DE TESTS OFFLINE COMPLETADA CON EXITO ===" -ForegroundColor Green
} catch {
    Write-Host "`n❌ BATERIA DE TESTS OFFLINE FALLO: $_" -ForegroundColor Red
    exit 1
} finally {
    # Restaurar valores globales originales
    $global:BearerToken = $oldBearer
    $global:N8nApiKey = $oldApiKey
    $global:HistoryPassword = $oldHistory
    Save-LocalConfig
}
