# Odoo 19 JSON-2 API Migration

## Deprecation Summary

The JSON-RPC API (`/jsonrpc` endpoint) is **deprecated in Odoo 19** and scheduled for removal:

| Milestone | Timeline |
|-----------|----------|
| Deprecated | Odoo 19 (current) |
| Removed from Odoo Online (SaaS) | Odoo 19.1 |
| Removed from Odoo.sh / on-premise | Odoo 20 (Fall 2026) |

**Affected endpoints**: `/xmlrpc`, `/xmlrpc/2`, `/jsonrpc`

**NOT affected**: Internal `@route(type='jsonrpc')` controllers (web client routes)

---

## The Replacement: JSON-2 API

Odoo 19 introduces the **External JSON-2 API** as the modern replacement for both XML-RPC and JSON-RPC.

### Endpoint Structure

```
POST /json/2/<model>/<method>
```

Examples:
- `POST /json/2/res.partner/search_read`
- `POST /json/2/ir.model/search`
- `POST /json/2/sale.order/create`

### Authentication

**Old (JSON-RPC)**:
- Username + password sent to `common/login`
- Returns `uid` (user ID)
- Subsequent calls include `uid` + password

**New (JSON-2)**:
- API keys only (bearer token)
- No username/password in requests
- No uid required

```http
Authorization: bearer <api_key>
```

API keys are created in Odoo via: **Preferences → Account Security → New API Key**

Keys are 160-bit random values, shown only once at creation.

### Request Format

**Old (JSON-RPC)**:
```json
POST /jsonrpc
{
  "jsonrpc": "2.0",
  "method": "call",
  "params": {
    "service": "object",
    "method": "execute_kw",
    "args": [
      "database",
      2,
      "password",
      "res.partner",
      "search_read",
      [[["is_company", "=", true]]],
      {"fields": ["name", "email"], "limit": 10}
    ]
  },
  "id": 1
}
```

**New (JSON-2)**:
```json
POST /json/2/res.partner/search_read
{
  "domain": [["is_company", "=", true]],
  "fields": ["name", "email"],
  "limit": 10
}
```

### Required Headers

| Header | Purpose |
|--------|---------|
| `Authorization` | `bearer <api_key>` |
| `Content-Type` | `application/json` |
| `X-Odoo-Database` | Database name (required for multi-database setups) |

### Response Format

**Success (HTTP 200)**:
```json
[
  {"id": 1, "name": "Company A", "email": "a@example.com"},
  {"id": 2, "name": "Company B", "email": "b@example.com"}
]
```

The method result is returned directly without JSON-RPC envelope.

**Error (HTTP 4xx/5xx)**:
```json
{
  "name": "odoo.exceptions.AccessError",
  "message": "You are not allowed to access 'Contact' (res.partner) records.",
  "arguments": ["You are not allowed to access 'Contact' (res.partner) records."],
  "context": {},
  "debug": "Traceback (most recent call last):..."
}
```

### Key Improvements

| Aspect | Old JSON-RPC | New JSON-2 |
|--------|--------------|------------|
| Endpoint | Single `/jsonrpc` | RESTful `/json/2/<model>/<method>` |
| Authentication | Password-based + uid | API key (bearer token) |
| Request format | JSON-RPC 2.0 envelope | Direct JSON parameters |
| HTTP status codes | Always 200 | Proper 4xx/5xx semantics |
| Big integer support | Serialization limits | Fixed |
| Documentation | Manual | Auto-generated at `/doc` |

### Additional Endpoints

| Endpoint | Replaces |
|----------|----------|
| `GET /web/version` | `common.version` method |
| `GET /doc` | N/A (new - auto-generated API docs) |

---

## Migration Impact on This Connector

### Current Implementation

The connector currently uses:

1. **JsonRpc.pqm**: Sends requests to `/jsonrpc` with JSON-RPC 2.0 envelope
2. **Odoo.Login()**: Calls `common/login` with username/password, gets `uid`
3. **Odoo.ExecuteKW()**: Uses `execute_kw` pattern with uid + password

### Required Changes

#### 1. New API Module

Create `Json2.pqm` to replace `JsonRpc.pqm`:

```powerquery
// Conceptual implementation
Json2.Call = (connection as record, model as text, method as text, params as record) =>
    let
        url = connection[url] & "/json/2/" & model & "/" & method,
        headers = [
            #"Authorization" = "bearer " & connection[api_key],
            #"Content-Type" = "application/json",
            #"X-Odoo-Database" = connection[db]
        ],
        response = Web.Contents(url, [
            Headers = headers,
            Content = Json.FromValue(params)
        ])
    in
        Json.Document(response);
```

#### 2. Authentication Overhaul

**Current flow**:
```
Odoo.Contents(url, db) → Odoo.Login(username, password) → uid
```

**New flow**:
```
Odoo.Contents(url, db, api_key) → connection record with api_key
```

The connector's authentication UI will need to accept an API key instead of (or in addition to) username/password.

#### 3. Remove JSON-RPC Envelope

**Current** (in JsonRpc.pqm):
```powerquery
body = [
    jsonrpc = "2.0",
    method = "call",
    params = [service = service, method = method, args = args],
    id = 1
]
```

**New**: Direct parameter passing without envelope.

#### 4. Error Handling

**Current**: Check `result.error` in JSON-RPC response
**New**: Check HTTP status codes (4xx/5xx) and parse error response body

#### 5. Update Odoo.ExecuteKW

The signature changes from:
```powerquery
Odoo.ExecuteKW(connection, model, method, args, kwargs)
// Where args includes [db, uid, password, model, method, ...]
```

To:
```powerquery
Odoo.ExecuteKW(connection, model, method, params)
// Where params is just the method parameters
```

---

## Backward Compatibility Strategy

### Option A: Dual Support

Maintain both JSON-RPC (Odoo ≤18) and JSON-2 (Odoo ≥19) with version detection:

```powerquery
Odoo.Call = (connection, model, method, params) =>
    if connection[odoo_version] >= 19 then
        Json2.Call(connection, model, method, params)
    else
        JsonRpc.Call(connection, "object", "execute_kw", [...])
```

Detect version via `GET /web/version` (works on both old and new).

### Option B: JSON-2 Only

Drop support for Odoo <19 and simplify codebase. This may be acceptable given:
- Odoo 19 releases ~Oct 2025
- Odoo typically supports 3 versions (17, 18, 19)
- By Fall 2026 (Odoo 20), versions <17 are unsupported anyway

### Option C: Separate Connectors

Maintain two separate `.mez` files:
- `Odoo.mez` (legacy JSON-RPC for Odoo ≤18)
- `Odoo19.mez` (JSON-2 for Odoo ≥19)

---

## Access Restrictions

**Important**: The JSON-2 API documentation notes:

> Access to data via the external API is only available on _Custom_ Odoo pricing plans.

This excludes Free and Standard tiers from using the external API. This is the same restriction that applied to JSON-RPC/XML-RPC.

---

## References

- [External JSON-2 API — Odoo 19.0 documentation](https://www.odoo.com/documentation/19.0/developer/reference/external_api.html)
- [External RPC API (deprecated) — Odoo 19.0 documentation](https://www.odoo.com/documentation/19.0/developer/reference/external_rpc_api.html)
- [XMLRPC is dead. All Hail JSON-2 (Odoo Experience 2025)](https://oduist.com/blog/odoo-experience-2025-ai-summaries-2/286-xmlrpc-is-dead-all-hail-json-2-288)
