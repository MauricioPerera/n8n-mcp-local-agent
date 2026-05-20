# Plan de Implementación: API Key de n8n Opcional

Hacer que la API Key de n8n (`N8nApiKey`) sea completamente opcional. Si el usuario no la proporciona, el agente local MCP se inicializará de forma limpia sin bloqueos, y las funcionalidades específicas que dependen de la API de n8n se deshabilitarán de forma elegante, mostrando al usuario cómo activarlas en caso de requerirlas.

## Cambios Propuestos

### 1. Inicialización de la API Key en el Cliente MCP
- **Archivo**: [mcp-client-n8n-final.ps1](file:///d:/repos/n8n-mcp-local-agent/mcp-client-n8n-final.ps1)
- **Modificación**: Cambiar el valor por defecto de `$global:N8nApiKey` para que, en lugar de usar `"YOUR_N8N_API_KEY_HERE"`, use una cadena vacía `""` o `$null`.
- **Modificación**: Actualizar la función `Load-LocalConfig` para que no requiera comparar contra `"YOUR_N8N_API_KEY_HERE"` para saber si hay una clave válida cargada desde el entorno o desde `config.json`.

### 2. Validación Robusta y Elegante de API Key (`apiKeyValid`)
- **Modificación**: Establecer una validación centralizada o verificar `$apiKeyValid` considerando la ausencia de claves vacías, nulas, o el antiguo placeholder:
  ```powershell
  $apiKeyValid = $global:N8nApiKey -and $global:N8nApiKey.Trim() -ne "" -and $global:N8nApiKey -ne "YOUR_N8N_API_KEY_HERE"
  ```
- **Modificación**: Omitir silenciosamente el inicio de la sincronización en segundo plano de ejecuciones (`/history -sync`) si la API Key no es válida, sin mostrar errores de inicio.

### 3. Deshabilitación de Comandos Dependientes con Advertencias Claras
Para los comandos que dependen de la API de n8n, si `$apiKeyValid` es falso, mostraremos una advertencia clara con `Write-Host` en color amarillo y un consejo (`HINT`) en color cian para indicarle al usuario cómo configurarlo:

- **`/credentials -create`**:
  ```powershell
  Write-Host "  [!] ADVERTENCIA: La funcion de crear credenciales esta deshabilitada porque no se ha configurado una API Key de n8n." -ForegroundColor Yellow
  Write-Host "  HINT: Configura tu API Key usando '/apikey TU_API_KEY' o definiendo la variable de entorno `$env:N8N_API_KEY`." -ForegroundColor Cyan
  ```
- **`/history -sync`**:
  ```powershell
  Write-Host "  [!] ADVERTENCIA: La sincronizacion del historial esta deshabilitada porque no se ha configurado una API Key de n8n." -ForegroundColor Yellow
  Write-Host "  HINT: Configura tu API Key usando '/apikey TU_API_KEY' o ejecutando '/history -sync TU_API_KEY'." -ForegroundColor Cyan
  ```
- **`/history -diagnose`**:
  ```powershell
  Write-Host "  [!] ADVERTENCIA: El diagnostico de ejecuciones esta deshabilitado porque no se ha configurado una API Key de n8n." -ForegroundColor Yellow
  Write-Host "  HINT: Configura tu API Key usando '/apikey TU_API_KEY' o definiendo la variable de entorno `$env:N8N_API_KEY`." -ForegroundColor Cyan
  ```

---

## Plan de Verificación

### Pruebas Manuales
1. **Inicio sin API Key**:
   - Borrar temporalmente `$env:N8N_API_KEY` de la sesión.
   - Eliminar `N8nApiKey` de `d:\repos\n8n-mcp-local-agent\n8n-executions-db\config.json`.
   - Iniciar el cliente: `powershell -File mcp-client-n8n-final.ps1 -DryRun`.
   - Verificar que inicia limpiamente, sin advertencias en rojo de sincronización ni bloqueos.
   
2. **Ejecutar comandos deshabilitados**:
   - En la consola interactiva, ejecutar `/history -sync`. Verificar que muestra la advertencia en amarillo y el HINT en cian.
   - Ejecutar `/history -diagnose 123`. Verificar que muestra la advertencia y el HINT.
   - Ejecutar `/credentials -create slackSlack "Mi Slack" "{}"`. Verificar que muestra la advertencia y el HINT.
   
3. **Ejecutar comandos permitidos en modo Offline/Local**:
   - Ejecutar `/variables -list` o `/variables -set test "value"`. Verificar que funciona.
   - Simular una consulta del usuario (por ejemplo, "crea una data table"). Verificar que el pipeline de enrutamiento y guardrails funciona perfectamente offline usando Ollama local.
   
4. **Configuración dinámica de API Key**:
   - En el cliente interactivo, ejecutar `/apikey MI_SUPER_KEY_VALIDA`.
   - Verificar con `/status` que la clave se ha guardado y enmascarado correctamente en config.json.
   - Verificar que ahora `/history -sync` intente conectar con la clave provista.

### Pruebas Automatizadas
- Ejecutar `run-tests.cmd` para garantizar que la batería de pruebas existente (de Node.js y PowerShell) pase al 100% y no haya ninguna regresión.
