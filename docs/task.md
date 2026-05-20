# Checklist: API Key de n8n Opcional

## 1. Modificar Cliente MCP (`mcp-client-n8n-final.ps1`)
- `[x]` Cambiar el valor por defecto de `$global:N8nApiKey` de `"YOUR_N8N_API_KEY_HERE"` a `""`.
- `[x]` Modificar `Load-LocalConfig` para que no use el placeholder en las comparaciones de carga.
- `[x]` Definir y validar `$apiKeyValid` considerando valores nulos, vacíos o el antiguo placeholder.
- `[x]` Condicionar la sincronización en segundo plano al arrancar el cliente (`$canSync`) para omitirse si la clave no está configurada.

## 2. Condicionar Comandos en el Bucle Interactivo
- `[x]` Condicionar el comando `/history -sync` para mostrar una advertencia clara y un HINT si la clave no está configurada.
- `[x]` Condicionar el comando `/history -diagnose` para mostrar una advertencia y HINT si no se tiene una clave válida.
- `[x]` Condicionar el comando `/credentials -create` para mostrar advertencia y HINT en ausencia de la clave.

## 3. Verificación y Regresión
- `[x]` Ejecutar las pruebas manuales offline (sin API Key).
- `[x]` Ejecutar comandos `/apikey` de forma dinámica para validar que se guarden y reactiven las funciones.
- `[x]` Ejecutar el script `run-tests.cmd` para asegurar que las pruebas unitarias pasan al 100%.
- `[x]` Guardar la documentación e implementation plan en el repositorio y subir los cambios a GitHub.
