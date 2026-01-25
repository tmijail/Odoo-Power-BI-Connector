---
name: pq-sdk-review
description: Review Power Query connector code against SDK best practices. Use when modifying Table.View handlers, schema handling, navigation tables, or authentication in .pq/.pqm files.
---

# Power Query SDK Best Practices Review

Review connector code against patterns from the Power Query SDK documentation (TripPin tutorial).

## When to Use

- Modifying `Table.View` implementations or query folding handlers
- Changing schema handling or type enforcement
- Updating navigation tables
- Modifying authentication flows
- Performance optimization
- Adding new data source functions

## Review Checklist

### Table.View (Query Folding)

```
[ ] GetType returns cached schema type, never fetches data
[ ] GetRows is the only handler that makes HTTP requests
[ ] State accumulated via recursive @View(newState) calls
[ ] Diagnostics.WrapHandlers wraps handler record for error tracing
[ ] Unimplemented handlers return ... to fall back to local processing
```

**Anti-pattern** (causes duplicate requests):
```powerquery
GetType = () => Value.Type(FetchData())  // BAD: fetches data
```

**Correct pattern**:
```powerquery
GetType = () => CalculateSchema(state),  // GOOD: uses cached schema
CalculateSchema = (state) => if state[Schema]? = null then GetSchemaForEntity(entity) else state[Schema]
```

### Schema Handling

```
[ ] Schema cached in state or connection, not re-fetched per call
[ ] Value.ReplaceType sets table type to avoid Power Query type inference
[ ] SchemaTransformTable or Table.ChangeType enforces column types
[ ] Nested records/lists use Table.ChangeType for recursive enforcement
```

### Navigation Tables

```
[ ] Table.ToNavigationTable adds required metadata fields
[ ] IsLeaf=false for expandable nodes, true for data tables
[ ] ItemKind matches content type (Table, Function, Database, etc.)
[ ] Lazy evaluation preferred (Table.InsertRows over Table.FromRecords)
```

### Authentication & Security

```
[ ] TestConnection handler enables Gateway refresh support
[ ] Credentials accessed via Extension.CurrentCredential()
[ ] Auth errors surface clearly to user
[ ] HTTPS enforced for certified connectors (ValidateUrlScheme)
[ ] Credentials never embedded in URLs or logs
[ ] All functions with same DataSource.Kind have identical required parameters
```

### Web.Contents Usage

```
[ ] ManualStatusHandling for expected error codes (400, 404, etc.)
[ ] Timeout set appropriately for slow endpoints
[ ] IsRetry = true when bypassing cache is needed
[ ] Response metadata checked for status when using ManualStatusHandling
```

**Pattern for error handling:**
```powerquery
response = Web.Contents(url, [ManualStatusHandling = {400, 404, 500}]),
status = Value.Metadata(response)[Response.Status],
body = if status = 200 then Json.Document(response) else error Error.Record(...)
```

### Performance

```
[ ] No duplicate HTTP requests during preview/type inference
[ ] Pagination uses Table.GenerateByPage pattern
[ ] Avoid eager evaluation in nav tables
[ ] Metadata requests cached where possible (fields_get, version, etc.)
```

### Error Handling

```
[ ] Custom errors use Error.Record with Reason, Message, Detail
[ ] Errors from API responses parsed and re-raised with context
[ ] try/catch used appropriately for fallback behavior
```

**Standard error reasons:** `Expression.Error`, `DataSource.Error`, `DataFormat.Error`

## Reference

- SDK docs: https://github.com/MicrosoftDocs/powerquery-docs
- TripPin tutorial: `powerquery-docs/samples/trippin/` (10 parts)
- Part 10 (`10-tableview1/`) has complete Table.View implementation
- See `thoughts/json2-sdk-review.md` for analysis of this codebase
- See `thoughts/power-query-connector-reference.md` for comprehensive reference
