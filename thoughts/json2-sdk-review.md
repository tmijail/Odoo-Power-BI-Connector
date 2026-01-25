# JSON-2 Implementation Plan Review: Power Query SDK Best Practices

Review of `json2-implementation-plan.md` against patterns from the Power Query SDK documentation (specifically the TripPin tutorial at `samples/trippin/`).

## What's Already Good

1. **Table.View pattern** - `Odoo.Search.View` correctly uses `Table.View` with `Diagnostics.WrapHandlers`
2. **Query folding handlers** - All key handlers implemented: `OnTake`, `OnSkip`, `OnSelectColumns`, `OnSort`, `GetRowCount`
3. **Helper functions** - Uses `SchemaTransformTable`, `Table.ToNavigationTable` consistent with SDK patterns
4. **Dual API support** - Version detection approach is sound

## Recommendations

### High Priority

#### 1. GetType Handler Makes Unnecessary HTTP Requests

**Current implementation** (`Odoo.pq:277-282`):
```powerquery
GetType = () =>
    let
        newParams = p & [limit=1],
        result = Value.Type(Odoo.Search(connection, model, sd, newParams, set_schema))
    in
        result,
```

This fetches actual data just to determine the type. The TripPin tutorial (part 6) explicitly warns against this - it causes duplicate requests and poor performance.

**TripPin pattern** (`10-tableview1/trippin.pq:120`):
```powerquery
GetType = () => CalculateSchema(state),

CalculateSchema = (state) as type =>
    if (state[Schema]? = null) then
        GetSchemaForEntity(entity)
    else
        state[Schema],
```

**Recommendation**: Cache schema in state. Derive `GetType` from cached schema, not from fetching data. This is an existing issue independent of JSON-2, but should be addressed as part of the refactor.

### Medium Priority

#### 2. TestConnection Handler Needs JSON-2 Awareness

The plan doesn't address updating `TestConnection` for JSON-2 API key authentication. This handler is required for Gateway refresh support.

**Current** (`Odoo.pq:17-23`):
```powerquery
TestConnection = (dataSourcePath) =>
    let
        json = Json.Document(dataSourcePath),
        URL = json[URL],
        Database = json[Database]
    in
        { "Odoo.Contents", URL, Database },
```

**Recommendation**: Ensure TestConnection works correctly with both auth methods. May need version-specific connection validation.

#### 3. Authentication UX Flow

The plan proposes:
```powerquery
Key = [
    Label = "API Key (Odoo ≥19)",
    KeyLabel = "API Key"
]
```

**Concern**: Users may not know their Odoo version when selecting authentication method.

**Options**:
- A) Accept both auth types, detect version after selection, show helpful error if mismatch
- B) Auto-detect version before showing auth options (requires unauthenticated `/web/version` call)
- C) Keep current approach but improve error messages

**Recommendation**: Option A is simplest. If user provides API key to Odoo <19, return clear error: "API key authentication requires Odoo 19+. Please use username/password."

### Low Priority

#### 4. Consider Single State Record Pattern

Current uses separate `sd` and `p` parameters:
```powerquery
View = (optional sd as list, optional p as record) => Table.View(null, [
    OnTake = (count) => @View(sd, newParams),
```

TripPin uses single state record:
```powerquery
View = (state as record) => Table.View(null, [
    OnTake = (count) => @View(state & [Top = count]),
```

**Recommendation**: Optional cleanup. Current approach works, but single state record is slightly cleaner and matches SDK examples more closely.

## Verification Checklist for JSON-2 Implementation

- [ ] `fields_get` returns same structure via JSON-2 (schema generation unchanged)
- [ ] Navigation table renders correctly with JSON-2 data
- [ ] Query folding works identically (limit/offset/fields/order parameters)
- [ ] Error responses properly surfaced to user (HTTP 4xx/5xx vs JSON-RPC error field)
- [ ] Gateway refresh works with API key auth (TestConnection handler)

## References

- TripPin Part 6 (Schema): Explains schema caching and `GetType` performance
- TripPin Part 10 (Query Folding): Complete `Table.View` implementation with state pattern
- `handling-navigation-tables.md`: Nav table metadata requirements
