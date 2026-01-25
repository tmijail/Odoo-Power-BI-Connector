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
```

### Navigation Tables

```
[ ] Table.ToNavigationTable adds required metadata fields
[ ] IsLeaf=false for expandable nodes, true for data tables
[ ] ItemKind matches content type (Table, Function, Database, etc.)
[ ] Lazy evaluation preferred (Table.InsertRows over Table.FromRecords)
```

### Authentication

```
[ ] TestConnection handler enables Gateway refresh support
[ ] Credentials accessed via Extension.CurrentCredential()
[ ] Auth errors surface clearly to user
```

### Performance

```
[ ] No duplicate HTTP requests during preview/type inference
[ ] Pagination uses Table.GenerateByPage pattern
[ ] Avoid eager evaluation in nav tables
```

## Reference

- SDK docs: https://github.com/MicrosoftDocs/powerquery-docs (`powerquery-docs/samples/trippin/`)
- Part 10 (`10-tableview1/`) has complete Table.View implementation
- See `thoughts/json2-sdk-review.md` for analysis of this codebase
