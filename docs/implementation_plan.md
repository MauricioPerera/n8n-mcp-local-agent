# Plan de Implementación: Batería de Tests Automatizados

Para garantizar la estabilidad y que "todo realmente funciona como debe", implementaré una batería de pruebas automatizadas mixtas (Node.js y PowerShell) sin requerir dependencias externas pesadas (como Jest o Pester), usando aserciones nativas para máxima compatibilidad.

## Alcance de las Pruebas

### 1. Pruebas Unitarias de Node.js (`test-suite.js`)
Probaré la lógica de validación, generación e inyección:
- **`validateLocal`**: Verificar que el validador estático del SDK detecte correctamente código bien formado y rechace errores de sintaxis o uso de `import`.
- **`stripImports`**: Verificar que las importaciones de ES6 se eliminen limpiamente sin romper el código.
- **`fillSlotsWithKV`** (Extraído de `update-workflow.js`): Verificar que si se pasa una variable tipo `__KV_nombre__`, la reemplace correctamente con el valor guardado en caché local, y si no existe, lo deje vacío.
- **`extractSlots`**: Mockear el LLM para probar el ensamblaje del prompt y garantizar que las variables disponibles se pasen correctamente en el sistema.

### 2. Pruebas Unitarias de PowerShell (`test-suite.ps1`)
Probaré el motor de enrutamiento estático (sin llamar al LLM):
- **Regex Clustering (`Get-ClusterByRegex`)**: Simular consultas de usuario como *"crea una data table"*, *"haz un workflow nuevo"*, *"dime los detalles del flujo"* y validar que caigan estrictamente en los clusters `DATA_TABLES`, `WORKFLOW_BUILD` y `WORKFLOW_MGMT` correspondientes.
- **Data Table Interceptor Regex**: Comprobar que el match de PowerShell captura todas las variantes de herramientas de Data Tables.

## Estructura
- Se crearán dos archivos: `n8n-validator/test-suite.js` y `test-suite.ps1`.
- Se correrán de forma automática con un script maestro `run-tests.cmd` para que puedas correr toda la batería en un solo clic.

**¿Te parece correcto este enfoque de pruebas unitarias sobre los motores principales?**
