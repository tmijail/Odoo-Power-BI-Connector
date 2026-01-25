# JSON-2 API Implementation Plan

This document outlines a test-driven development plan for adding Odoo 19+ JSON-2 API support while maintaining backward compatibility with JSON-RPC for legacy versions.

> **Related documentation**: See [odoo-19-json2-api-migration.md](./odoo-19-json2-api-migration.md) for details on the API deprecation timeline, JSON-2 request/response format, and authentication differences.
>
> **Validation**: This plan has been validated against the Odoo 19.0 source code. See [json2-validation-report.md](./json2-validation-report.md) for detailed findings.

## Overview

### Goals
1. Auto-detect Odoo version and select appropriate API
2. Support JSON-2 API for Odoo ≥19
3. Maintain JSON-RPC support for Odoo <19
4. Support both authentication methods (password and API key)
5. Minimize code duplication

### Key Changes
| Component | Current | New |
|-----------|---------|-----|
| Auth method | Username/password → uid | Username/password OR API key |
| Endpoint | `/jsonrpc` | `/jsonrpc` OR `/json/2/<model>/<method>` |
| Request format | JSON-RPC 2.0 envelope | Direct JSON OR JSON-RPC envelope |
| Connection record | `{url, db, uid}` | `{url, db, uid, api_version, api_key?}` |

---

## Phase 1: Version Detection

### 1.1 Test: Fetch Odoo Version
```powerquery
// Odoo.query.pq - Add test
Fact(
    "Check that we can detect Odoo version",
    try true,
    // Note: Odoo 19+ uses "version_info", legacy uses "server_version_info"
    // Odoo.GetMajorVersion handles both cases
    try Odoo.GetMajorVersion(url) >= 14
)
```

### 1.2 Implementation: Version Endpoint with Fallback

Version detection requires two strategies because the endpoints differ between Odoo versions:

1. **Odoo 19+**: The `/web/version` endpoint returns version info directly (no auth required)
2. **Odoo ≤18**: The `/web/version` endpoint doesn't exist; use `common.version` via JSON-RPC

**Strategy**: Try `/web/version` first. If it fails (404 or error), fall back to JSON-RPC `common.version`.

#### `/web/version` response (Odoo 19+):
```json
{
  "version": "19.0",
  "version_info": [19, 0, 0, "final", 0, ""]
}
```

> **Note**: The Odoo 19 `/web/version` endpoint uses different field names than the legacy
> `common.version` JSON-RPC call. The implementation must handle both formats.

#### `common.version` response (Odoo ≤18):
```json
{
  "server_version": "16.0",
  "server_version_info": [16, 0, 0, "final", 0, ""],
  "server_serie": "16.0",
  "protocol_version": 1
}
```

```powerquery
// Odoo.pq - Add function with fallback logic
Odoo.GetVersion = (url as text) as record =>
    let
        // First, try the new /web/version endpoint (Odoo 19+)
        webVersionResult = try
            let
                versionUrl = Uri.Combine(url, "web/version"),
                response = Web.Contents(versionUrl, [
                    Headers = [#"Content-Type" = "application/json"],
                    ManualStatusHandling = {404}
                ]),
                metadata = Value.Metadata(response),
                statusCode = metadata[Response.Status]
            in
                if statusCode = 404 then
                    null
                else
                    Json.Document(response)
        otherwise
            null,

        // If /web/version failed, fall back to JSON-RPC common.version (Odoo ≤18)
        result = if webVersionResult <> null then
            webVersionResult
        else
            JsonRpc.Call(url, "common", "version", {})
    in
        result;

// Helper to extract major version number
// Handles both Odoo 19+ format ("version_info") and legacy format ("server_version_info")
Odoo.GetMajorVersion = (url as text) as number =>
    let
        version = Odoo.GetVersion(url),
        // Odoo 19+ uses "version_info", legacy uses "server_version_info"
        versionInfo = if Record.HasFields(version, "version_info") then
            version[version_info]
        else
            version[server_version_info]
    in
        versionInfo{0};
```

### 1.3 Test: Version Detection Fallback
```powerquery
// Test that version detection works on both old and new Odoo versions
Fact(
    "Check version detection returns valid version info",
    try true,
    try
        let
            version = Odoo.GetVersion(url),
            // Odoo 19+ uses "version"/"version_info", legacy uses "server_version"/"server_version_info"
            hasVersion = Record.HasFields(version, "version") or Record.HasFields(version, "server_version"),
            hasVersionInfo = Record.HasFields(version, "version_info") or Record.HasFields(version, "server_version_info")
        in
            hasVersion and hasVersionInfo
)
```

### 1.3 Test: Version Comparison Logic
```powerquery
Fact(
    "Check that version 19+ uses JSON-2 API",
    try true,
    try Odoo.ShouldUseJson2(19) = true
),
Fact(
    "Check that version 18 uses JSON-RPC API",
    try true,
    try Odoo.ShouldUseJson2(18) = false
)
```

### 1.4 Implementation: Version Logic
```powerquery
Odoo.ShouldUseJson2 = (majorVersion as number) as logical =>
    majorVersion >= 19;
```

---

## Phase 2: JSON-2 API Module

### 2.1 Create `Json2.pqm`

New module for JSON-2 API communication.

### 2.2 Test: JSON-2 Request Format
```powerquery
// Test that JSON-2 requests are formatted correctly
Fact(
    "Check JSON-2 request builds correct URL",
    try "https://example.com/json/2/res.partner/search_read",
    try Json2.BuildUrl("https://example.com", "res.partner", "search_read")
)
```

### 2.3 Implementation: `Json2.pqm`
```powerquery
let
    // Build the JSON-2 endpoint URL
    Json2.BuildUrl = (baseUrl as text, model as text, method as text) as text =>
        Uri.Combine(baseUrl, "json/2/" & model & "/" & method),

    // Make a JSON-2 API call
    Json2.Call = (url as text, db as text, apiKey as text, model as text, method as text, params as record) =>
        let
            endpoint = Json2.BuildUrl(url, model, method),
            headers = [
                #"Authorization" = "Bearer " & apiKey,  // RFC 6750 standard: "Bearer" with capital B
                #"Content-Type" = "application/json",
                #"X-Odoo-Database" = db
            ],
            content = Json.FromValue(params),
            response = Web.Contents(endpoint, [
                Content = content,
                Headers = headers,
                // Handle all documented HTTP status codes
                ManualStatusHandling = {400, 401, 403, 404, 409, 415, 422, 500}
            ]),
            metadata = Value.Metadata(response),
            statusCode = metadata[Response.Status],
            body = Json.Document(response),
            result = if statusCode >= 400 then
                error [
                    Reason = body[name],
                    Message = body[message],
                    Detail = Record.FieldOrDefault(body, "debug", "")
                ]
            else
                body
        in
            result
in
    [
        BuildUrl = Json2.BuildUrl,
        Call = Json2.Call
    ]
```

---

## Phase 3: Unified API Abstraction

### 3.1 Test: Unified Call Works for Both APIs
```powerquery
// This test should work regardless of which API is used
Fact(
    "Check that Odoo.Execute works with auto-detected API",
    try true,
    try List.Count(Odoo.Execute(connection, "res.partner", "search_read",
        [domain = {}, fields = {"id", "name"}, limit = 1])) >= 0
)
```

### 3.2 Implementation: Unified `Odoo.Execute`

Replace the API-specific code path with a unified abstraction:

```powerquery
// New unified execution function
Odoo.Execute = (connection as record, model as text, method as text, params as record) =>
    if connection[api_version] = "json2" then
        Json2.Call(
            connection[url],
            connection[db],
            connection[api_key],
            model,
            method,
            params
        )
    else
        // Legacy JSON-RPC path
        Odoo.ExecuteKW(
            connection,
            model,
            method,
            { Record.FieldOrDefault(params, "domain", {}) },
            Record.RemoveFields(params, {"domain"}, MissingField.Ignore)
        );
```

---

## Phase 4: Authentication Overhaul

### 4.1 Update Authentication Configuration

The connector currently uses `UsernamePassword` auth. We need to support both:
- **Odoo <19**: Username + Password (existing)
- **Odoo ≥19**: API Key (new)

### 4.2 Test: API Key Authentication
```powerquery
// For Odoo 19+ test environment with API key
Fact(
    "Check that API key authentication works for JSON-2",
    try true,
    try
        let
            conn = Odoo.LoginWithApiKey(url, db, testApiKey),
            result = Odoo.Execute(conn, "res.partner", "search_read", [limit=1])
        in
            not List.IsEmpty(result)
)
```

### 4.3 Implementation: Dual Auth Support

**Option A: Auto-detect based on credential type**

Power BI allows multiple auth types. Update the connector to offer both:

```powerquery
Odoo = [
    TestConnection = (dataSourcePath) =>
        let
            json = Json.Document(dataSourcePath),
            URL = json[URL],
            Database = json[Database]
        in
            { "Odoo.Contents", URL, Database },
    Authentication = [
        UsernamePassword = [
            Label = "Username & Password (Odoo ≤18)"
        ],
        Key = [
            Label = "API Key (Odoo ≥19)",
            KeyLabel = "API Key"
        ]
    ],
    Label = Extension.LoadString("DataSourceLabel")
];
```

### 4.4 Implementation: Updated Login Flow

```powerquery
Odoo.Login = (url as text, db as text) as record =>
    let
        credentials = Extension.CurrentCredential(),
        majorVersion = Odoo.GetMajorVersion(url),
        useJson2 = Odoo.ShouldUseJson2(majorVersion),

        // Determine auth type from credentials
        hasApiKey = Record.HasFields(credentials, "Key"),
        hasPassword = Record.HasFields(credentials, "Password"),

        connection =
            if useJson2 and hasApiKey then
                // JSON-2 with API key (preferred for Odoo 19+)
                [
                    url = url,
                    db = db,
                    api_version = "json2",
                    api_key = credentials[Key],
                    odoo_version = majorVersion
                ]
            else if useJson2 and hasPassword then
                // JSON-2 with password - need to get/create API key or fall back
                // Note: JSON-2 doesn't support password auth directly
                // Option 1: Use JSON-RPC to authenticate, then use JSON-2
                // Option 2: Fall back to JSON-RPC entirely
                let
                    uid = Odoo.GetUID(url, db)
                in
                    [
                        url = url,
                        db = db,
                        uid = uid,
                        api_version = "jsonrpc",
                        odoo_version = majorVersion
                    ]
            else
                // Legacy JSON-RPC (Odoo <19 or fallback)
                let
                    uid = Odoo.GetUID(url, db)
                in
                    [
                        url = url,
                        db = db,
                        uid = uid,
                        api_version = "jsonrpc",
                        odoo_version = majorVersion
                    ]
    in
        connection;
```

---

## Phase 5: Update Core Functions

### 5.1 Test: search_read Works on Both APIs
```powerquery
Fact(
    "Check search_read works with detected API version",
    try true,
    try Table.RowCount(search_read("res.partner", {}, [limit=3])) = 3
)
```

### 5.2 Implementation: Update `Odoo._Search`

```powerquery
Odoo._Search = (connection as record, model as text, search_domain as list, optional params as record) =>
    let
        _params = if params <> null then params else [],
        result = if connection[api_version] = "json2" then
            Json2.Call(
                connection[url],
                connection[db],
                connection[api_key],
                model,
                "search_read",
                [domain = search_domain] & _params
            )
        else
            Odoo.ExecuteKW(
                connection,
                model,
                "search_read",
                { search_domain },
                _params
            )
    in
        Table.FromRecords(result);
```

### 5.3 Update Other Core Functions

Apply the same pattern to:
- `Odoo.SearchCount` → `search_count`
- `Odoo.ReadGroup` → `read_group`
- `Odoo.FieldsGet` → `fields_get`
- `Odoo.CheckPermissions` (uses `read_group` internally)

---

## Phase 6: Refactor Connection Management

### 6.1 Test: Connection Record Contains API Version
```powerquery
Fact(
    "Check connection record includes api_version",
    try true,
    try Record.HasFields(Odoo.Login(url, db), "api_version")
),
Fact(
    "Check connection record includes odoo_version",
    try true,
    try Record.HasFields(Odoo.Login(url, db), "odoo_version")
)
```

### 6.2 Implementation: Enhanced Connection Record

```powerquery
// Connection record structure for JSON-RPC
[
    url = "https://mycompany.odoo.com",
    db = "mydb",
    uid = 2,
    api_version = "jsonrpc",
    odoo_version = 18
]

// Connection record structure for JSON-2
[
    url = "https://mycompany.odoo.com",
    db = "mydb",
    api_version = "json2",
    api_key = "xxxxx",
    odoo_version = 19
]
```

---

## Phase 7: Error Handling

### 7.1 Test: JSON-2 Error Handling
```powerquery
Fact(
    "Check JSON-2 errors are properly formatted",
    try "werkzeug.exceptions.NotFound",  // Model not found returns NotFound
    try
        let
            result = try Odoo.Execute(connection, "nonexistent.model", "search_read", [])
        in
            result[Error][Reason]
)
```

### 7.2 JSON-2 Error Response Format

The JSON-2 API returns errors with these fields:
```json
{
  "name": "module.ExceptionClass",
  "message": "Human-readable error message",
  "arguments": ["array", "of", "exception", "args"],
  "context": {},
  "debug": "Full traceback (only in debug mode)"
}
```

### 7.3 HTTP Status Codes

| Status | Condition | Error Name |
|--------|-----------|------------|
| 200 | Success | - |
| 400 | Invalid JSON body | `werkzeug.exceptions.BadRequest` |
| 401 | Missing/invalid Bearer token | `werkzeug.exceptions.Unauthorized` |
| 403 | Access denied | `odoo.exceptions.AccessError` or `AccessDenied` |
| 404 | Model/method not found | `werkzeug.exceptions.NotFound` |
| 409 | Lock conflict | `odoo.exceptions.LockError` |
| 415 | Wrong Content-Type | `werkzeug.exceptions.UnsupportedMediaType` |
| 422 | Missing arguments, validation error | `werkzeug.exceptions.UnprocessableEntity` or `odoo.exceptions.UserError` |
| 500 | Unhandled exception | Various |

### 7.4 Common Error Messages

| Scenario | Message |
|----------|---------|
| Missing auth | "User not authenticated, use an API Key with a Bearer Authorization header." |
| Invalid API key | "Invalid apikey" |
| Model not found | "the model '{model}' does not exist" |
| Method not found | "{model} has no method {method}" |
| Missing argument | "missing a required argument: '{arg}'" |
| Access denied | "You are not allowed to access '{model_name}' ({model}) records..." |

### 7.5 Implementation: Unified Error Format

Both APIs should produce consistent error records:
```powerquery
error [
    Reason = "Error Type/Name",
    Message = "Human-readable message",
    Detail = "Debug traceback (if available)"
]
```

---

## Phase 8: Update Odoo.query.pq Test Suite

### 8.1 Add Version-Specific Tests

```powerquery
// Add to facts list
Fact(
    "Check Odoo version detection",
    try true,
    try Odoo.GetMajorVersion(url) >= 14
),
Fact(
    "Check connection has correct api_version",
    try true,
    try
        let
            conn = Odoo.Login(url, db),
            expectedApi = if Odoo.ShouldUseJson2(conn[odoo_version])
                          then "json2"
                          else "jsonrpc"
        in
            conn[api_version] = expectedApi or conn[api_version] = "jsonrpc"
)
```

### 8.2 Parameterized Test Environment

Update `test-server.json` to support both API types:
```json
{
    "url": "http://localhost:8069",
    "db": "db",
    "api_key": "test_api_key_for_json2_testing"
}
```

---

## Implementation Order (TDD Sequence)

### Sprint 1: Foundation (Version Detection)
1. Write tests for `Odoo.GetVersion`
2. Implement `Odoo.GetVersion`
3. Write tests for `Odoo.ShouldUseJson2`
4. Implement `Odoo.ShouldUseJson2`
5. Verify tests pass

### Sprint 2: JSON-2 Module
1. Create `Json2.pqm` skeleton
2. Write tests for `Json2.BuildUrl`
3. Implement `Json2.BuildUrl`
4. Write tests for `Json2.Call` (mock or use test server)
5. Implement `Json2.Call`
6. Verify tests pass

### Sprint 3: Authentication
1. Write tests for API key auth
2. Update `Odoo` data source definition with dual auth
3. Implement `Odoo.LoginWithApiKey`
4. Update `Odoo.Login` for dual auth detection
5. Verify tests pass

### Sprint 4: Core Functions Migration
1. Write tests for `Odoo._Search` with JSON-2
2. Update `Odoo._Search` with API branching
3. Repeat for `Odoo.SearchCount`, `Odoo.ReadGroup`, `Odoo.FieldsGet`
4. Verify tests pass

### Sprint 5: Integration & Cleanup
1. Run full test suite against Odoo 16/17/18 (JSON-RPC)
2. Run full test suite against Odoo 19+ (JSON-2)
3. Update documentation
4. Update `docker-compose.yml` for Odoo 19 testing
5. Final verification

---

## File Changes Summary

| File | Changes |
|------|---------|
| `Odoo.pq` | Add version detection, update login flow, add API branching to all methods |
| `JsonRpc.pqm` | No changes (keep for backward compat) |
| `Json2.pqm` | **NEW** - JSON-2 API implementation |
| `Odoo.query.pq` | Add version and API-specific tests |
| `test-server.json` | Add `api_key` field for JSON-2 testing |
| `docker-compose.yml` | Add Odoo 19 service for testing |
| `Odoo.proj` | Add `Json2.pqm` to content files |
| `resources.resx` | Add labels for API key auth UI |

---

## Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| `/web/version` doesn't exist on Odoo ≤18 | Fall back to `common.version` via JSON-RPC (see Phase 1.2) |
| `/web/version` blocked by auth | This endpoint is public on Odoo 19+; fallback handles older versions |
| API key not available on all Odoo plans | Fall back to JSON-RPC with password auth |
| Breaking changes for existing users | API version auto-detection ensures transparent upgrade |
| Odoo 19 not yet widely deployed | Default to JSON-RPC unless version ≥19 detected |

---

## Testing Environments

### Docker Compose (Updated)
```yaml
services:
  # Existing: Odoo 16 for JSON-RPC testing
  web:
    image: odoo:16.0
    ports:
      - "8069:8069"
    depends_on:
      - db
    environment:
      - HOST=db
      - USER=odoo
      - PASSWORD=odoo

  # New: Odoo 19 for JSON-2 testing
  web19:
    image: odoo:19.0
    ports:
      - "8070:8069"
    depends_on:
      - db
    environment:
      - HOST=db
      - USER=odoo
      - PASSWORD=odoo

  db:
    image: postgres:15
    environment:
      - POSTGRES_DB=postgres
      - POSTGRES_PASSWORD=odoo
      - POSTGRES_USER=odoo
```

### Test Configuration
```json
// test-server-jsonrpc.json (Odoo 16-18)
{
    "url": "http://localhost:8069",
    "db": "db"
}

// test-server-json2.json (Odoo 19+)
{
    "url": "http://localhost:8070",
    "db": "db",
    "api_key": "generated_during_setup"
}
```

---

## Success Criteria

1. All existing tests pass on Odoo 16/17/18 (JSON-RPC)
2. All tests pass on Odoo 19+ (JSON-2)
3. Version auto-detection works correctly
4. Both auth methods (password and API key) work
5. Transparent upgrade path for existing users
6. No breaking changes to public API functions
