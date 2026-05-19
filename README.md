# n8n MCP Local Agent v3.0

Create n8n workflows from natural language using a local LLM pipeline.

## What is this?

A local agent that converts natural language queries into functional n8n workflows, validates them locally using the official SDK, and deploys them to a remote n8n instance via MCP (Model Context Protocol).

**Key design decisions:**
- **Deterministic validation first**: Code is parsed and validated with `@n8n/workflow-sdk` *before* touching the remote server
- **No blind guessing**: If validation fails, the pipeline aborts with a clear error
- **Credential detection**: Warns you which nodes need credentials before activation
- **Small models only**: Uses `qwen2.5:0.5b` (~400MB) and `embeddinggemma` (~600MB) — no cloud LLM required

## Architecture

```
User Query
    |
    v
[1] Template Matcher (keyword-based, threshold 15%)
    |
    |---> Match found ------> [2] Slot Detection & Filling
    |                           (channel, text, url, to, subject)
    |                               |
    |---> No match ----------> [LLM Fallback]
    |                           qwen2.5:0.5b (3 retries + error feedback)
    |                               |
    v                               v
[3] Local SDK Validation (@n8n/workflow-sdk)
    |   - Parses code
    |   - Validates structure
    |   - Detects credential nodes
    |   - EMPTY_WORKFLOW guard
    |
    v
[4] Deploy via MCP HTTP (only if local validation passes)
```

## Requirements

- **Ollama** running locally with:
  - `qwen2.5:0.5b` (~400MB, router + generator)
  - `embeddinggemma:latest` (~600MB, embeddings)
- **Node.js** v18+ (for `@n8n/workflow-sdk`)
- **PowerShell 7+**
- **n8n MCP Bearer Token** (set via environment variable)

## Installation

```bash
# Clone the repository
git clone https://github.com/yourusername/n8n-mcp-local-agent.git
cd n8n-mcp-local-agent

# Install Node.js dependencies
cd n8n-validator
npm install
cd ..
```

## Configuration

**Never hardcode your token.** Use an environment variable:

```powershell
# PowerShell
$env:N8N_BEARER_TOKEN = "your-jwt-bearer-token-here"

# Or set it permanently in your profile
[Environment]::SetEnvironmentVariable("N8N_BEARER_TOKEN", "your-token", "User")
```

**Default MCP server URL:** `https://ardf.dev/mcp-server/http`

Override with:
```powershell
$env:N8N_MCP_URL = "https://your-instance.com/mcp-server/http"
```

## Usage

### CLI: Create a workflow directly

```powershell
& .\create-n8n-workflow.ps1 -Query "create a slack notification webhook that sends Server down to #alerts"
```

Output:
```
✅ WORKFLOW CREADO EXITOSAMENTE
  🆔 ID:       abc123def456
  📛 Nombre:   Slack Notification
  📊 Nodos:    2
  🔗 URL:      https://ardf.dev/workflow/abc123def456

⚠️  CREDENCIALES REQUERIDAS:
   • Send Message (n8n-nodes-base.slack)

💡 Configura las credenciales en n8n antes de activar.
```

### Dry run (preview without deploying)

```powershell
& .\create-n8n-workflow.ps1 -Query "create an email alert" -DryRun
```

### Interactive client

```powershell
# Simplified client (v3 pipeline only)
& .\mcp-client-v3.ps1

# Full client (embeddings + guardrails + all MCP tools)
& .\mcp-client-n8n-final.ps1
```

### Available commands (interactive v3)

- `create <description>` — Create a workflow from template or LLM
- `list` — List existing workflows
- `salir` / `exit` — Quit

## Templates

| Template | Description | Slots | Credentials |
|---|---|---|---|
| `webhook_echo` | Webhook → JSON response | — | No |
| `cron_http` | Schedule trigger → HTTP request | — | No |
| `form_submit` | Webhook → Google Sheets | — | Google |
| `slack_notification` | Webhook → Slack | `channel`, `text` | Slack |
| `email_alert` | Webhook → SMTP | `to`, `subject` | SMTP |
| `telegram_alert` | Webhook → Telegram | `chatId`, `text` | Telegram |
| `webhook_filter` | Webhook → IF condition → Email | — | Email |

## Pipeline v3 Details

### 1. Template Matching
- Extracts keywords from the query
- Compares against template keywords (threshold: 15% match)
- Best match wins; ties broken by keyword coverage

### 2. Slot Filling
Detects parameterized fields in the template:
- `channel`: `#channel-name`
- `text`: text after "sends", "with", "message"
- `url`: `https://...` URLs
- `to`: `email@domain.com`
- `subject`: text after "subject" or "about"

### 3. Local Validation
Runs `@n8n/workflow-sdk` to:
- Parse the code AST
- Validate node structure (types, versions, connections)
- Detect credential-required nodes
- Reject empty workflows (`EMPTY_WORKFLOW` error)

### 4. LLM Fallback
If no template matches (score < 15%):
- Sends query to `qwen2.5:0.5b` with strict prompt rules
- Validates generated code
- Retries up to 3 times with error feedback
- Aborts if all attempts fail (never sends invalid code to MCP)

## File Structure

```
.
├── create-n8n-workflow.ps1      # CLI entry point
├── mcp-client-v3.ps1            # Interactive client (simplified)
├── mcp-client-n8n-final.ps1     # Interactive client (full pipeline v2)
├── arg-extractor-v2.psm1      # PowerShell module: argument extraction + template filling
├── local-validator.psm1       # PowerShell module: local SDK validation wrapper
├── tool-schemas.json          # Strict schema definitions for MCP tools
├── workflow-templates.json    # 7 pre-built workflow templates
├── README.md                  # This file
├── .gitignore                 # Git ignore rules
└── n8n-validator/
    ├── package.json           # Node.js dependencies
    ├── workflow-builder-v2.js # Pipeline v3 engine (Node.js)
    ├── validate-sdk.js        # SDK validator with EMPTY_WORKFLOW guard
    ├── sdk-generator.js       # LLM fallback generator with retry
    └── template-filler.js     # Slot detection and filling
```

## Security Notes

- **No tokens are hardcoded** in production scripts. Set `N8N_BEARER_TOKEN` as an environment variable.
- **Local validation prevents bad code** from reaching your n8n server.
- **Credential detection** warns you before activating workflows that need API keys.

## Troubleshooting

### "No template match and LLM generation failed"
The query does not match any known template, and the 0.5B model could not generate valid code in 3 attempts. Try:
- Rephrasing with keywords from the templates (slack, email, telegram, webhook, cron, form)
- Using `-DryRun` to inspect the generated code

### "Workflow has no nodes" (EMPTY_WORKFLOW)
The LLM generated code that parses but contains no nodes. This is caught locally before reaching the server.

### Ollama not responding
Make sure Ollama is running:
```bash
ollama serve
ollama pull qwen2.5:0.5b
ollama pull embeddinggemma:latest
```

### MCP connection errors
Verify your bearer token:
```powershell
$env:N8N_BEARER_TOKEN  # Should show your token
```

## Benchmarks

| Model | Params | Tool Accuracy | Speed | Role |
|---|---|---|---|---|
| functiongemma | 270M | 2/5 | Fast | Discarded |
| gemma3:270m | 270M | 1/5 | Fast | Discarded |
| **qwen2.5:0.5b** | **500M** | **4/5** | **Fast** | **✅ Recommended** |
| granite4:350m | 350M | 2/5 | Fast | Discarded |
| granite4:1b | 1B | 3/5 | Medium | Possible |

## License

MIT
