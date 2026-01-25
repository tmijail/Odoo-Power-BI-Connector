# Power Query Custom Connector Development Reference

Comprehensive reference for developing Power Query (M Language) custom connectors for Power BI.

## Extension Structure

```powerquery
[Version = "1.0.0"]
section MyConnector;

// Data source definition
MyConnector = [
    TestConnection = (dataSourcePath) => { "MyConnector.Contents", Json.Document(dataSourcePath)[server] },
    Authentication = [
        UsernamePassword = [],
        Key = [KeyLabel = "API Key"]
    ],
    Label = "My Connector"
];

// Publishing metadata (Get Data dialog)
MyConnector.Publish = [
    Beta = true,
    Category = "Other",
    ButtonText = { "My Connector", "Connect to My Service" },
    LearnMoreUrl = "https://example.com/docs",
    SourceImage = MyConnector.Icons,
    SourceTypeImage = MyConnector.Icons
];

// Main entry point
[DataSource.Kind="MyConnector", Publish="MyConnector.Publish"]
shared MyConnector.Contents = (server as text) as table => ...;

// Internal function (same auth, not published)
[DataSource.Kind="MyConnector"]
shared MyConnector.Query = (server as text, query as text) as table => ...;
```

**Key rules:**
- Functions with same `DataSource.Kind` must have identical required parameters (used for credential caching)
- `shared` exports the function; without it, function is section-private
- `Publish` attribute makes function visible in Get Data dialog

## Authentication Types

| Type | Record Fields | Credential Access |
|------|---------------|-------------------|
| `Anonymous = []` | (none) | N/A |
| `UsernamePassword = []` | UsernameLabel, PasswordLabel, Label | `[Username]`, `[Password]` |
| `Key = []` | KeyLabel, Label | `[Key]` |
| `OAuth = []` | StartLogin, FinishLogin, Refresh, Logout, Label | `[access_token]` |
| `Aad = []` | AuthorizationUri, Resource, Scope, ScopePrefix | `[access_token]` |
| `Windows = []` | UsernameLabel, PasswordLabel, Label, SupportsAlternateCredentials | `[Username]`, `[Password]` |
| `Implicit = []` | (none) | Inherited from wrapped function |

```powerquery
// Access credentials
cred = Extension.CurrentCredential(),
username = cred[Username],
password = cred[Password],
apiKey = cred[Key],
token = cred[access_token],
authKind = cred[AuthenticationKind]
```

### OAuth Implementation

```powerquery
Authentication = [
    OAuth = [
        StartLogin = (resourceUrl, state, display) =>
            let
                authorizeUrl = "https://auth.example.com/authorize?" & Uri.BuildQueryString([
                    client_id = client_id,
                    redirect_uri = redirect_uri,
                    response_type = "code",
                    state = state
                ])
            in
                [LoginUri = authorizeUrl, CallbackUri = redirect_uri, WindowHeight = 720, WindowWidth = 1024, Context = null],

        FinishLogin = (context, callbackUri, state) =>
            let
                parts = Uri.Parts(callbackUri)[Query],
                token = TokenMethod("authorization_code", "code", parts[code])
            in
                token,

        Refresh = (resourceUrl, refresh_token) => TokenMethod("refresh_token", "refresh_token", refresh_token),

        Logout = (token) => "https://auth.example.com/logout"
    ]
]
```

## Data Access Functions

### Web.Contents (REST APIs)

```powerquery
response = Web.Contents(url, [
    Headers = [
        #"Authorization" = "Bearer " & token,
        #"Content-Type" = "application/json",
        #"Accept" = "application/json"
    ],
    Content = Json.FromValue(body),           // POST body (binary)
    Query = [param1 = "value1"],              // URL query params
    Timeout = #duration(0, 0, 30, 0),         // 30 seconds
    ManualStatusHandling = {400, 404, 500},   // Don't error on these
    ManualCredentials = true,                 // Skip auto-auth
    IsRetry = true                            // Bypass cache
]),
json = Json.Document(response),
status = Value.Metadata(response)[Response.Status]
```

**ManualStatusHandling**: By default, 4xx/5xx throw errors. Use this to handle them manually.

### OData.Feed (OData Services)

```powerquery
// Automatic schema, nav tables, and query folding
source = OData.Feed("https://services.odata.org/v4/TripPinService/", null, [
    Implementation = "2.0",
    ODataVersion = 4,
    MoreColumns = true
])
```

## Navigation Tables

Navigation tables display hierarchical data in the Navigator dialog.

```powerquery
Table.ToNavigationTable = (
    table as table,
    keyColumns as list,      // Primary key columns
    nameColumn as text,      // Display name
    dataColumn as text,      // Table/Function to load
    itemKindColumn as text,  // Icon type
    itemNameColumn as text,  // Preview behavior (usually same as itemKind)
    isLeafColumn as text     // true = data node, false = expandable container
) as table =>
    let
        tableType = Value.Type(table),
        newTableType = Type.AddTableKey(tableType, keyColumns, true) meta [
            NavigationTable.NameColumn = nameColumn,
            NavigationTable.DataColumn = dataColumn,
            NavigationTable.ItemKindColumn = itemKindColumn,
            Preview.DelayColumn = itemNameColumn,
            NavigationTable.IsLeafColumn = isLeafColumn
        ]
    in
        Value.ReplaceType(table, newTableType);
```

**ItemKind values**: `Table`, `Function`, `Database`, `DatabaseServer`, `Folder`, `Feed`, `View`, `Sheet`, `DefinedName`, `Record`, `Dimension`

**Example:**

```powerquery
CreateNavTable = (connection) =>
    let
        objects = #table(
            {"Name", "Key", "Data", "ItemKind", "ItemName", "IsLeaf"},
            {
                {"Tables", "tables", GetTablesNavTable(connection), "Folder", "Folder", false},
                {"Functions", "funcs", GetFunctionsNavTable(connection), "Folder", "Folder", false}
            }
        )
    in
        Table.ToNavigationTable(objects, {"Key"}, "Name", "Data", "ItemKind", "ItemName", "IsLeaf");
```

## Query Folding with Table.View

Query folding pushes transformations to the data source. Implement via `Table.View`:

```powerquery
MyConnector.View = (connection as record, entity as text) as table =>
    let
        // Recursive view function with state accumulation
        View = (state as record) => Table.View(null, [

            // Return table type (MUST NOT fetch data)
            GetType = () => GetSchemaForEntity(state[Entity]),

            // Fetch actual data (called last)
            GetRows = () =>
                let
                    url = BuildUrl(state),
                    schema = GetSchemaForEntity(state[Entity]),
                    data = FetchData(url, schema)
                in
                    Table.ChangeType(data, schema),

            // Table.FirstN → LIMIT
            OnTake = (count as number) =>
                @View(state & [Top = count]),

            // Table.Skip → OFFSET
            OnSkip = (count as number) =>
                @View(state & [Skip = count]),

            // Table.SelectColumns → fields/select
            OnSelectColumns = (columns as list) =>
                let
                    currentSchema = GetSchemaForEntity(state[Entity]),
                    newSchema = FilterSchemaColumns(currentSchema, columns)
                in
                    @View(state & [SelectColumns = columns, Schema = newSchema]),

            // Table.Sort → ORDER BY
            OnSort = (order as list) =>
                let
                    // order = {[Name = "col", Order = Order.Ascending], ...}
                    orderText = Text.Combine(
                        List.Transform(order, (o) =>
                            o[Name] & " " & (if o[Order] = Order.Ascending then "asc" else "desc")
                        ),
                        ", "
                    )
                in
                    @View(state & [OrderBy = orderText]),

            // Table.RowCount
            GetRowCount = () as number =>
                // Return ... to fall back to local counting if can't fold
                if Record.FieldCount(Record.RemoveFields(state, {"Url", "Entity"}, MissingField.Ignore)) > 0 then
                    ...
                else
                    GetCount(state),

            // Table.SelectRows with simple conditions (advanced)
            OnSelectRows = (selector as function) =>
                let
                    // Parse selector AST - complex, see SDK examples
                    filter = ParseFilter(selector)
                in
                    if filter = null then ... else @View(state & [Filter = filter]),

            // Table.AddColumn (advanced)
            OnAddColumn = (name as text, selector as function, type as type) => ...,

            // Table.Group (advanced)
            OnGroup = (keys as list, aggregates as list) => ...
        ])
    in
        View([Url = connection[url], Entity = entity]);
```

**Important:**
- `GetType` must return cached schema, never fetch data (causes double requests)
- Return `...` from any handler to fall back to local processing
- Use `@View` for recursive calls (@ prevents premature evaluation)
- Wrap handlers with `Diagnostics.WrapHandlers` for error tracing

## Pagination

```powerquery
Table.GenerateByPage = (getNextPage as function) as table =>
    let
        listOfPages = List.Generate(
            () => getNextPage(null),
            (lastPage) => lastPage <> null,
            (lastPage) => getNextPage(lastPage)
        ),
        tableOfPages = Table.FromList(listOfPages, Splitter.SplitByNothing(), {"Column1"}),
        firstRow = tableOfPages{0}?
    in
        if firstRow = null then
            Table.FromRows({})
        else if Table.IsEmpty(firstRow[Column1]) then
            firstRow[Column1]
        else
            Value.ReplaceType(
                Table.ExpandTableColumn(tableOfPages, "Column1", Table.ColumnNames(firstRow[Column1])),
                Value.Type(firstRow[Column1])
            );

// Usage
GetAllPages = (url as text, schema as type) as table =>
    Table.GenerateByPage((previous) =>
        let
            nextLink = if previous = null then url else Value.Metadata(previous)[NextLink]?,
            page = if nextLink = null then null else GetPage(nextLink, schema)
        in
            page
    );

GetPage = (url as text, schema as type) as table =>
    let
        response = Web.Contents(url),
        json = Json.Document(response),
        nextLink = json[nextLink]?,  // or parse from headers
        data = Table.FromRecords(json[value])
    in
        data meta [NextLink = nextLink];
```

## Schema Enforcement

### Simple: SchemaTransformTable

```powerquery
EnforceSchema.Strict = 1;               // Add missing, remove extra, set type
EnforceSchema.IgnoreExtraColumns = 2;   // Add missing, keep extra
EnforceSchema.IgnoreMissingColumns = 3; // Keep as-is

schema = #table({"Name", "Type"}, {
    {"id", Int64.Type},
    {"name", type text},
    {"created_at", type datetime},
    {"amount", Currency.Type},
    {"is_active", type logical},
    {"metadata", type record},      // Not transformed (complex type)
    {"tags", type list}             // Not transformed (complex type)
});

result = SchemaTransformTable(data, schema, EnforceSchema.Strict);
```

### Advanced: Table.ChangeType (Recursive)

```powerquery
// Define nested types
AddressType = type [
    street = text,
    city = text,
    zip = text
];

PersonType = type table [
    id = Int64.Type,
    name = text,
    email = nullable text,
    address = AddressType,              // Nested record
    phones = {text},                    // List of text
    orders = {nullable OrderType}       // List of nullable records
];

// Apply recursively
result = Table.ChangeType(data, PersonType);
```

**Key difference**: `SchemaTransformTable` only handles top-level columns. `Table.ChangeType` recursively enforces types on nested records and lists.

## Gateway Support (TestConnection)

Required for scheduled refresh through on-premises data gateway:

```powerquery
MyConnector = [
    TestConnection = (dataSourcePath) =>
        let
            json = Json.Document(dataSourcePath),
            server = json[server],
            database = json[database]
        in
            // Return: {FunctionName, arg1, arg2, ...}
            { "MyConnector.Contents", server, database },

    Authentication = [...]
];
```

The `dataSourcePath` is JSON-serialized connection parameters. Return a list with function name and arguments that will test the connection.

## Diagnostics

```powerquery
Diagnostics = Extension.LoadFunction("Diagnostics.pqm");
Diagnostics.LogValue = Diagnostics[LogValue];
Diagnostics.LogFailure = Diagnostics[LogFailure];
Diagnostics.WrapHandlers = Diagnostics[WrapHandlers];

// Log a value and return it
url = Diagnostics.LogValue("Requesting URL", baseUrl & path),

// Log on failure, return result or re-raise error
result = Diagnostics.LogFailure("API call failed", () => Web.Contents(url)),

// Wrap Table.View handlers for automatic error tracing
View = (state) => Table.View(null, Diagnostics.WrapHandlers([
    GetType = () => ...,
    GetRows = () => ...
]))
```

Enable diagnostics in Power Query SDK or via `Diagnostics.ActivityId`.

## Loading External Modules

```powerquery
Extension.LoadFunction = (fileName as text) =>
    let
        binary = Extension.Contents(fileName),
        asText = Text.FromBinary(binary)
    in
        Expression.Evaluate(asText, #shared);

// Load module
JsonRpc = Extension.LoadFunction("JsonRpc.pqm");
JsonRpc.Call = JsonRpc[Call];

// Load resources
Icons = [
    Icon16 = { Extension.Contents("icon16.png"), Extension.Contents("icon20.png") },
    Icon32 = { Extension.Contents("icon32.png"), Extension.Contents("icon40.png") }
];

// Load localized strings
Label = Extension.LoadString("DataSourceLabel");
```

## Error Handling

```powerquery
// Raise custom error
error Error.Record("MyConnector.Error", "Something went wrong", [Details = "extra info"])

// Raise with standard reason
error [
    Reason = "DataSource.Error",
    Message = "Connection failed",
    Detail = responseBody
]

// Handle errors
result = try riskyOperation()
         catch (e) => if e[Reason] = "DataSource.Error" then fallback else error e

// Check for error
tryResult = try riskyOperation(),
if tryResult[HasError] then
    handleError(tryResult[Error])
else
    tryResult[Value]
```

**Standard error reasons**: `Expression.Error`, `DataSource.Error`, `DataFormat.Error`, `Evaluation.Error`

## Type System Quick Reference

```powerquery
// Primitive types
type null, type logical, type number, type text, type binary,
type date, type time, type datetime, type datetimezone, type duration,
type list, type record, type table, type function, type type, type any, type none

// Ascribed types (specific number formats)
Int8.Type, Int16.Type, Int32.Type, Int64.Type,
Single.Type, Double.Type, Decimal.Type,
Currency.Type, Percentage.Type

// Nullable
type nullable text

// List with item type
{text}              // list of text
{nullable number}   // list of nullable numbers

// Record with field types
type [name = text, age = number, email = nullable text]

// Table with column types
type table [id = Int64.Type, name = text, created = datetime]

// Type operations
Type.Is(valueType, type text)                    // Check if compatible
Type.ListItem(listType)                          // Get list item type
Type.RecordFields(recordType)                    // Get field definitions
Type.TableRow(tableType)                         // Get row record type
Type.ForRecord(fieldRecord, isOpen)              // Create record type
Value.Type(value)                                // Get value's type
Value.ReplaceType(value, newType)                // Set type metadata
```

## URI Helpers

```powerquery
// Parse URL
parts = Uri.Parts("https://api.example.com:8080/path?a=1&b=2#section"),
// [Scheme="https", Host="api.example.com", Port=8080, Path="/path",
//  Query=[a="1", b="2"], Fragment="section"]

// Build query string
qs = Uri.BuildQueryString([a = "1", b = "hello world"]),  // "a=1&b=hello%20world"

// Combine paths
url = Uri.Combine("https://api.example.com/v1/", "users"),  // .../v1/users

// Reconstruct URL from parts
Uri.FromParts = (parts) =>
    let
        port = if (parts[Scheme] = "https" and parts[Port] = 443)
               or (parts[Scheme] = "http" and parts[Port] = 80) then ""
               else ":" & Text.From(parts[Port]),
        div1 = if Record.FieldCount(parts[Query]) > 0 then "?" else "",
        div2 = if Text.Length(parts[Fragment]) > 0 then "#" else ""
    in
        Text.Combine({parts[Scheme], "://", parts[Host], port, parts[Path],
                      div1, Uri.BuildQueryString(parts[Query]), div2, parts[Fragment]});
```

## Testing

### Unit Tests with Facts

```powerquery
// In MyConnector.query.pq
let
    // Test framework
    Fact = (name as text, expected, actual) =>
        let
            result = try actual,
            passed = not result[HasError] and result[Value] = expected
        in
            [Name = name, Expected = expected, Actual = if result[HasError] then result[Error] else result[Value], Passed = passed],

    Facts = {
        Fact("Basic connection", true, MyConnector.Contents("server") <> null),
        Fact("Query returns table", true, Value.Is(MyConnector.Query("server", "test"), type table)),
        Fact("Row count", 10, Table.RowCount(Table.FirstN(MyConnector.Contents("server"){[Name="Users"]}[Data], 10)))
    },

    Results = Table.FromRecords(Facts),
    Passed = Table.SelectRows(Results, each [Passed] = true),
    Failed = Table.SelectRows(Results, each [Passed] = false)
in
    if Table.RowCount(Failed) > 0 then Failed else "All " & Text.From(Table.RowCount(Passed)) & " tests passed"
```

### CLI Testing with PQTest

```bash
# Set credentials
echo '{"AuthenticationKind":"UsernamePassword","AuthenticationProperties":{"Username":"user","Password":"pass"},"PrivacySetting":"None","Permissions":[]}' | \
  PQTest.exe set-credential -e bin/Debug/MyConnector.mez -q MyConnector.query.pq

# Run tests
PQTest.exe compare -e bin/Debug/MyConnector.mez -q MyConnector.query.pq -p

# Run with folding validation (fails if query doesn't fold)
PQTest.exe compare -e bin/Debug/MyConnector.mez -q MyConnector.query.pq -p --errorOnFoldingFailure
```

## Build Configuration

**MyConnector.proj:**
```xml
<Project Sdk="Microsoft.PowerQuery.Sdk/0.3.0">
  <PropertyGroup>
    <ExtensionName>MyConnector</ExtensionName>
    <OutputType>extension</OutputType>
  </PropertyGroup>
</Project>
```

**Build:** `dotnet build MyConnector.proj`

**Output:** `bin/AnyCPU/Debug/MyConnector.mez` (ZIP file with .pq, .pqm, resources)

## References

- SDK Docs: https://github.com/MicrosoftDocs/powerquery-docs
- M Language Reference: https://learn.microsoft.com/powerquery-m/
- TripPin Tutorial: `powerquery-docs/samples/trippin/` (10-part progressive tutorial)
- Helper Functions: `powerquery-docs/helper-functions.md`
