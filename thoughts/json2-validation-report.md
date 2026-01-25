# JSON-2 Implementation Plan Validation Report

**Date**: 2026-01-25
**Source**: Odoo 19.0 branch from https://github.com/odoo/odoo
**Validated against**: `thoughts/json2-implementation-plan.md`

---

## Executive Summary

The implementation plan is **mostly accurate** but contains several **critical discrepancies** that must be corrected before implementation. The most significant issue is the `/web/version` endpoint response format, which differs from what's documented in the plan.

---

## 1. `/web/version` Endpoint

### Endpoint Details (VERIFIED)
| Aspect | Plan | Actual (Odoo 19) | Status |
|--------|------|------------------|--------|
| URL | `/web/version` | `/web/version` OR `/json/version` | **CORRECT** (bonus: alternate URL available) |
| Method | GET | GET | **CORRECT** |
| Auth | None required | `auth='none'` | **CORRECT** |

**Source**: `/tmp/odoo-19/addons/rpc/controllers/__init__.py:24-29`

### Response Format (CRITICAL DISCREPANCY)

**Plan says:**
```json
{
  "server_version": "19.0",
  "server_version_info": [19, 0, 0, "final", 0, ""],
  "server_serie": "19.0",
  "protocol_version": 1
}
```

**Actual response:**
```json
{
  "version": "19.0",
  "version_info": [19, 0, 0, "final", 0, ""]
}
```

**Issues:**
1. Field `server_version` should be `version`
2. Field `server_version_info` should be `version_info`
3. Fields `server_serie` and `protocol_version` **do not exist**

**Source**: `/tmp/odoo-19/addons/rpc/controllers/__init__.py:26-28`
```python
return request.make_json_response({
    'version_info': odoo.release.version_info,
    'version': odoo.release.version,
})
```

### Required Code Fix

```powerquery
// WRONG (from plan)
Odoo.GetVersion(url)[server_version_info]{0}

// CORRECT
Odoo.GetVersion(url)[version_info]{0}
```

---

## 2. `/json/2/<model>/<method>` Endpoint

### Endpoint Details (VERIFIED)
| Aspect | Plan | Actual | Status |
|--------|------|--------|--------|
| URL Pattern | `/json/2/<model>/<method>` | `/json/2/<__model__>/<__method__>` | **CORRECT** |
| Method | POST | POST only | **CORRECT** |
| Auth | Bearer token | `auth='bearer'` | **CORRECT** |

**Source**: `/tmp/odoo-19/addons/rpc/controllers/json2.py:49-56`

### Request Parameters (VERIFIED)

The JSON-2 endpoint accepts these special parameters:
- `ids`: Sequence of record IDs (optional, default `()`)
- `context`: Mapping for context (optional, default `frozendict()`)
- `**kwargs`: Additional method-specific parameters

**Source**: `/tmp/odoo-19/addons/rpc/controllers/json2.py:57-64`

---

## 3. Required Headers

### Authorization Header (MINOR DISCREPANCY)

**Plan says:**
```
Authorization: bearer <api_key>
```

**Actual:**
- Case-insensitive matching via regex: `^bearer\s+(.+)$` (with `re.IGNORECASE`)
- Standard convention is `Bearer` (capital B)

**Recommendation:** Use `Bearer` (capital B) for standards compliance:
```
Authorization: Bearer <api_key>
```

**Source**: `/tmp/odoo-19/odoo/addons/base/models/ir_http.py:221`

### Database Header (VERIFIED)

**Plan says:** `X-Odoo-Database`
**Actual:** `X-Odoo-Database` (canonical name, case-insensitive)

**Source**: `/tmp/odoo-19/odoo/http.py:1780`

### Content-Type Header (VERIFIED)

**Required:** `Content-Type: application/json`

---

## 4. Error Response Format

### Structure (VERIFIED)

**Plan says:**
```json
{
  "name": "odoo.exceptions.AccessError",
  "message": "Human-readable message",
  "debug": "Traceback..."
}
```

**Actual (complete structure):**
```json
{
  "name": "module.ExceptionClass",
  "message": "Error message",
  "arguments": [...],
  "context": {},
  "debug": "Traceback (most recent call last):..."
}
```

**Source**: `/tmp/odoo-19/odoo/http.py:459-469`

```python
def serialize_exception(exception, *, message=None, arguments=None):
    return {
        'name': f'{module}.{name}' if module else name,
        'message': exception_to_unicode(exception) if message is None else message,
        'arguments': exception.args if arguments is None else arguments,
        'context': getattr(exception, 'context', {}),
        'debug': ''.join(traceback.format_exception(exception)),
    }
```

**Note:** The plan omits `arguments` and `context` fields. Update error handling code to handle all 5 fields.

---

## 5. HTTP Status Codes (COMPLETE MAPPING)

| Status | Exception/Condition | Plan Mentions |
|--------|---------------------|---------------|
| **200** | Success | Yes |
| **400** | `BadRequest` - Invalid JSON body | No |
| **401** | `Unauthorized` - Missing/invalid Bearer token | No |
| **403** | `Forbidden` - `AccessError`, `AccessDenied`, `SessionExpiredException` | Partial |
| **404** | `NotFound` - Model/method doesn't exist, `MissingError` | Partial |
| **409** | `Conflict` - `LockError` | No |
| **415** | `UnsupportedMediaType` - Wrong Content-Type | No |
| **422** | `UnprocessableEntity` - Missing arguments, `UserError`, `ValidationError` | No |
| **500** | `InternalServerError` - Unhandled exceptions | Yes |

**Sources**:
- `/tmp/odoo-19/odoo/exceptions.py:15,50,84,106,116`
- `/tmp/odoo-19/odoo/http.py:2617-2639`

---

## 6. Specific Error Messages

### Authentication Errors

| Scenario | HTTP Status | Error Name | Message |
|----------|-------------|------------|---------|
| Missing auth | 401 | `werkzeug.exceptions.Unauthorized` | "User not authenticated, use an API Key with a Bearer Authorization header." |
| Invalid API key | 401 | `werkzeug.exceptions.Unauthorized` | "Invalid apikey" |
| Session/header conflict | 403 | `werkzeug.exceptions.Forbidden` | "Cannot use both the session_id cookie and the x-odoo-database header." |

### Request Errors

| Scenario | HTTP Status | Error Name | Message |
|----------|-------------|------------|---------|
| Invalid JSON | 400 | `werkzeug.exceptions.BadRequest` | "could not parse the body as json: {details}" |
| Missing argument | 422 | `werkzeug.exceptions.UnprocessableEntity` | "missing a required argument: '{arg}'" |
| Model not found | 404 | `werkzeug.exceptions.NotFound` | "the model '{model}' does not exist" |
| Method not found | 404 | `werkzeug.exceptions.NotFound` | "{model} has no method {method}" |
| IDs with @api.model | 422 | `werkzeug.exceptions.UnprocessableEntity` | "cannot call {model}.{method} with ids" |
| Wrong endpoint format | 404 | `werkzeug.exceptions.NotFound` | "Did you mean POST /json/2/<model>/<method>?" |

### Access Errors

| Scenario | HTTP Status | Error Name | Message Example |
|----------|-------------|------------|-----------------|
| No read access | 403 | `odoo.exceptions.AccessError` | "You are not allowed to access '{model_name}' ({model}) records..." |

**Source**: `/tmp/odoo-19/odoo/addons/test_http/tests/test_webjson2.py`

---

## 7. API Key Generation

### Scope (IMPORTANT)

API keys for JSON-2 use scope `'rpc'` (or `NULL` for global keys):

```python
# From test setup
key = user.env['res.users.apikeys']._generate(
    scope='rpc',
    name='test',
    expiration_date=datetime.now() + timedelta(days=0.5)
)
```

**Note**: The `'rpc'` scope doesn't actually exist as a restriction - it effectively requires a global key (scope NULL).

**Source**: `/tmp/odoo-19/odoo/addons/base/models/ir_http.py:238-239`
```python
# 'rpc' scope does not really exist, we basically require a global key (scope NULL)
uid = request.env['res.users.apikeys']._check_credentials(scope='rpc', key=token)
```

---

## 8. Additional Findings

### Fallback for Missing Method

When calling `/json/2/<model>` without a method:
- Returns 404
- Message: "Did you mean POST /json/2/<model>/<method>?"

### URL Parameter vs Body Parameter Security

The endpoint correctly prioritizes URL parameters over body parameters to prevent injection:

```python
# URL parameters (__model__, __method__) take precedence
# Body parameters cannot override them
```

**Source**: `/tmp/odoo-19/odoo/addons/test_http/tests/test_webjson2.py:234-252`

### WWW-Authenticate Header

On 401 responses, the server returns:
```
WWW-Authenticate: bearer
```

---

## 9. Required Plan Updates

### Critical Fixes

1. **Version endpoint response** - Change field names:
   - `server_version` -> `version`
   - `server_version_info` -> `version_info`
   - Remove references to `server_serie` and `protocol_version`

2. **Error response** - Add missing fields to error handling:
   - `arguments`
   - `context`

### Recommended Updates

3. **Authorization header** - Use `Bearer` (capital B) for standards compliance

4. **HTTP status codes** - Document complete mapping (400, 401, 409, 415, 422)

5. **Specific error messages** - Document exact error messages for better error handling

---

## 10. Verified Code Paths

| File | Line | Purpose |
|------|------|---------|
| `addons/rpc/controllers/__init__.py` | 24-29 | `/web/version` endpoint |
| `addons/rpc/controllers/json2.py` | 49-90 | JSON-2 API controller |
| `odoo/http.py` | 2584-2639 | `Json2Dispatcher` class |
| `odoo/http.py` | 459-469 | `serialize_exception()` function |
| `odoo/addons/base/models/ir_http.py` | 214-254 | `_auth_method_bearer()` |
| `odoo/addons/base/models/res_users.py` | 1572-1589 | `_check_credentials()` for API keys |
| `odoo/exceptions.py` | 9-116 | Exception classes with `http_status` |

---

## Conclusion

The implementation plan is fundamentally sound, but the **version endpoint response format discrepancy is critical** and will cause the connector to fail if not corrected. The error handling code should also be updated to handle all 5 fields in error responses.

All other aspects of the plan (URL patterns, authentication mechanism, request/response formats) have been validated against the Odoo 19 source code and are accurate.
