# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a Power Query custom data connector that enables Microsoft Power BI to query data from Odoo ERP systems via JSON-RPC API. It's designed for cloud-hosted Odoo instances (like odoo.sh) where direct database access isn't available.

**Language**: Power Query (M Language) - Microsoft's functional query language for data transformation.

## Build Commands

Build and deploy via VS Code:
- **Ctrl+Shift+B** or `Terminal > Run Task > "Build and copy to Customs Connectors folder"`

This compiles to `bin\AnyCPU\Debug\Odoo.mez` and copies it to the Power BI custom connectors folder.

## Testing

Start the test Odoo instance:
```bash
docker-compose up
```

Then in VS Code:
1. Open Power Query SDK sidebar, click "Set credential"
2. Enter test database credentials
3. Open `Odoo.query.pq`
4. Click "Evaluate current file"

Test configuration is in `test-server.json` (default: `http://localhost:8069`, database `db`).

## Architecture

### Core Files

| File | Purpose |
|------|---------|
| `Odoo.pq` | Main connector: authentication, API functions, navigation table, query folding |
| `JsonRpc.pqm` | Low-level JSON-RPC 2.0 protocol implementation |
| `Schema.pqm` | Type mapping between Odoo field types and Power Query types |
| `Table.pqm` | Navigation table construction for Power BI UI |
| `Diagnostics.pqm` | Logging and value serialization utilities |
| `Odoo.query.pq` | Unit tests using Fact-based assertions |

### Connection Flow

```
Power BI → Odoo.Contents(url, db) → Odoo.Login() → JsonRpc.Call("common", "login")
    → Creates connection record {url, db, uid}
    → Odoo.CreateNavTable() builds navigation tree with Functions and Tables nodes
```

### Query Execution Flow

```
search_read(model, domain, params)
    → Odoo.Search.View() [implements query folding]
    → Odoo.ExecuteKW() → JsonRpc.Call()
    → Data processing: false→null, many2one→records, schema enforcement
    → Typed table returned to Power BI
```

### Query Folding

`Odoo.Search.View()` implements Power BI table view handlers for server-side optimization:
- `OnTake(n)` → LIMIT
- `OnSkip(n)` → OFFSET
- `OnSelectColumns(cols)` → fields parameter
- `OnSort(order)` → ORDER BY
- `GetRowCount()` → search_count

### Public API Functions

- `Odoo.Search()` / `Odoo.Search.View()`: Query records with filtering
- `Odoo.SearchCount()`: Count matching records
- `Odoo.ReadGroup()`: Group and aggregate data
- `Odoo.ExecuteKW()`: Low-level wrapper for arbitrary Odoo model methods

## Key Patterns

**Odoo type translation**: `Odoo.TranslateType()` maps Odoo types (char, integer, many2one, etc.) to M Language types.

**Nullable field handling**: Non-logical fields with false values are converted to null.

**many2one conversion**: Odoo returns `[id, name]` pairs, converted to `{id, name}` records.

**Permission filtering**: one2many fields are filtered based on user access rights to related models.

## Important: Odoo 19 API Deprecation

The JSON-RPC API (`/jsonrpc`) used by this connector is **deprecated in Odoo 19** and will be removed in Odoo 20 (Fall 2026). The replacement is the JSON-2 API with different authentication (API keys) and request format. See `thoughts/odoo-19-json2-api-migration.md` for migration details.
