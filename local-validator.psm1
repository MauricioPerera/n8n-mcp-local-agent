$script:ValidatorPath = Join-Path $PSScriptRoot "n8n-validator\validate-sdk.js"

function Invoke-LocalSDKValidation($code) {
    $tempFile = [System.IO.Path]::GetTempFileName() + ".js"
    try {
        Set-Content -Path $tempFile -Value $code -Encoding UTF8
        $output = & node $script:ValidatorPath $tempFile 2>&1
        $result = $output | ConvertFrom-Json
        return $result
    } catch {
        return @{
            valid = $false
            parsed = $false
            errors = @(@{ code = 'VALIDATOR_EXCEPTION'; message = $_.Exception.Message })
            hint = "Local validator crashed: $($_.Exception.Message)"
            requiresCredentials = $false
            credentialNodes = @()
        }
    } finally {
        if (Test-Path $tempFile) { Remove-Item $tempFile -Force }
    }
}

function Show-ValidationReport($result) {
    if ($result.valid) {
        Write-Host "  ✅ SDK valido localmente" -ForegroundColor Green
        if ($result.requiresCredentials) {
            Write-Host "  ⚠️  Este workflow requiere credenciales para los siguientes nodos:" -ForegroundColor Yellow
            foreach ($cn in $result.credentialNodes) {
                Write-Host "     • $($cn.name) ($($cn.type))" -ForegroundColor Yellow
            }
            Write-Host "  💡 Debes configurar las credenciales en n8n antes de activar este workflow." -ForegroundColor Cyan
        }
        if ($result.warnings -and $result.warnings.Count -gt 0) {
            Write-Host "  ⚠️  Advertencias:" -ForegroundColor DarkYellow
            foreach ($w in $result.warnings) { Write-Host "     • $($w.message)" -ForegroundColor DarkYellow }
        }
    } else {
        Write-Host "  ❌ SDK invalido:" -ForegroundColor Red
        foreach ($err in $result.errors) {
            Write-Host "     • [$($err.code)] $($err.message)" -ForegroundColor Red
        }
    }
}

Export-ModuleMember -Function Invoke-LocalSDKValidation, Show-ValidationReport
