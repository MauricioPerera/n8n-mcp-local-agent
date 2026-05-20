# Checklist: Batería de Pruebas Automatizadas

## 1. Pruebas Node.js (`test-suite.js`)
- `[x]` **Refactorización mínima**: Exportar `validateLocal`, `stripImports` de `workflow-builder.js` para que puedan ser requeridos. Exportar `fillSlotsWithKV` de `update-workflow.js`.
- `[x]` **Test: validateLocal**: Verificar que detecte código válido e inválido (ej. con `import`).
- `[x]` **Test: stripImports**: Verificar que remueva imports de ES6.
- `[x]` **Test: fillSlotsWithKV**: Verificar la correcta sustitución de `__KV_xxx__` con valores reales.

## 2. Pruebas PowerShell (`test-suite.ps1`)
- `[x]` **Test: Regex Clustering**: Aislar `Get-ClusterByRegex` y el array `$ClusterPatterns`.
- `[x]` Validar que frases como *"crea una data table"* caen en `DATA_TABLES`.
- `[x]` Validar que frases de workflow caen en `WORKFLOW_BUILD` o `WORKFLOW_MGMT`.
- `[x]` **Test: Data Table Regex**: Validar que la regex usada en la línea 1457 de `mcp-client-n8n-final.ps1` (`$toolName -match 'data_table' -and $toolName -ne 'search_data_tables'`) hace match correctamente a las herramientas deseadas y no a `search_data_tables`.

## 3. Script Maestro (`run-tests.cmd`)
- `[x]` Crear script CMD para ejecutar ambas suites y presentar los resultados unificados.
