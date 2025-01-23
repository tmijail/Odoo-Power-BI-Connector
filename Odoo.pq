[Version = "1.1.0"]
section Odoo;

shared Odoo.TestServer = Json.Document(Text.FromBinary(Extension.Contents("test-server.json")));

[DataSource.Kind="Odoo", Publish="Odoo.Publish"]
shared Odoo.Contents = (URL as text, Database as text) =>
    let
        connection = Odoo.Login(URL, Database),
        navTable = Odoo.CreateNavTable(connection)
    in
        navTable;


// Data Source Kind description
Odoo = [
    TestConnection = (dataSourcePath) =>
        let
            json = Json.Document(dataSourcePath),
            URL = json[URL],
            Database = json[Database]
        in
            { "Odoo.Contents", URL, Database },
    Authentication = [
        UsernamePassword = []
    ],
    Label = Extension.LoadString("DataSourceLabel")
];


// Data Source UI publishing description
Odoo.Publish = [
    Beta = true,
    Category = "Other",
    ButtonText = { Extension.LoadString("ButtonTitle"), Extension.LoadString("ButtonHelp") },
    LearnMoreUrl = "https://github.com/tmijail/Odoo-Power-BI-Connector",
    SourceImage = Odoo.Icons,
    SourceTypeImage = Odoo.Icons
];


Odoo.Icons = [
    Icon16 = { Extension.Contents("Odoo16.png"), Extension.Contents("Odoo20.png"), Extension.Contents("Odoo24.png"), Extension.Contents("Odoo32.png") },
    Icon32 = { Extension.Contents("Odoo32.png"), Extension.Contents("Odoo40.png"), Extension.Contents("Odoo48.png"), Extension.Contents("Odoo64.png") }
];


/************************************************
 ******************* Includes *******************
 ************************************************/


Extension.LoadFunction = (fileName as text) =>
  let
      binary = Extension.Contents(fileName),
      asText = Text.FromBinary(binary)
  in
      try
        Expression.Evaluate(asText, #shared)
      catch (e) =>
        error [
            Reason = "Extension.LoadFunction Failure",
            Message.Format = "Loading '#{0}' failed - '#{1}': '#{2}'",
            Message.Parameters = {fileName, e[Reason], e[Message]},
            Detail = [File = fileName, Error = e]
        ];

JsonRpc = Extension.LoadFunction("JsonRpc.pqm");
JsonRpc.Request = JsonRpc[Request];
JsonRpc.Call = JsonRpc[Call];

Schema = Extension.LoadFunction("Schema.pqm");
EnforceSchema.Strict = Schema[EnforceSchema.Strict];
EnforceSchema.IgnoreExtraColumns = Schema[EnforceSchema.IgnoreExtraColumns];
EnforceSchema.IgnoreMissingColumns = Schema[EnforceSchema.IgnoreMissingColumns];
SchemaTransformTable = Schema[SchemaTransformTable];

Table = Extension.LoadFunction("Table.pqm");
Table.ToNavigationTable = Table[ToNavigationTable];
Table.GenerateContainerLeaf = Table[GenerateContainerLeaf];

Diagnostics = Extension.LoadFunction("Diagnostics.pqm");
Diagnostics.LogValue = Diagnostics[LogValue];
Diagnostics.LogFailure = Diagnostics[LogFailure];
Diagnostics.WrapHandlers = Diagnostics[WrapHandlers];


/**********************************************
 ******************** Odoo ********************
 **********************************************/


 Odoo.Databases = (url as text) as list =>
     JsonRpc.Call(Uri.Combine(url, "jsonrpc"), "db", "list", {});


// Finds the uid of the Odoo User.
 Odoo.GetUID = (url as text, db as text) as number =>
     let 
        credentials = Extension.CurrentCredential(),
        jsonrpc_url = Uri.Combine(url, "jsonrpc"),
        uid = JsonRpc.Call(jsonrpc_url, "common", "login", { db, credentials[Username], credentials[Password] }),
        result = if uid = false then error "Odoo authentication error" else uid
    in
        result;


// Finds the uid of the Odoo User and saves all the information needed to connect to the db in the `connection` record.
Odoo.Login = (url as text, db as text) as record =>
    let
        uid = Diagnostics.LogValue("Logging in as UID", Odoo.GetUID(url, db)),
        connection = [url = url,
                      db = db,
                      uid = uid]
    in
        connection;


/* Wrapper arround `JsonRPC.Call` that handles authentication through the `connection` record created by `Odoo.Login`
 *
 * This function produces an HTTP POST request with roughly the following content:
 *     {"jsonrpc": "2.0",
 *      "method": "call",
 *      "params": {"service": service,
 *                 "method": method,
 *                 "args": [db,
 *                          uid,
 *                          password,
 *                          arg1,
 *                          arg2]},
 *      "id": 135468}
 */
Odoo.Call = (connection as record, service as text, method as text, args as list) =>
    let
        jsonrpc_url = Uri.Combine( connection[url], "jsonrpc"),
        result = JsonRpc.Call( jsonrpc_url, 
                               service, 
                               method, 
                               { connection[db], 
                                 connection[uid], 
                                 Extension.CurrentCredential()[Password]} 
                                 & args )
    in 
        result;


/* Executes a backend function with the members of the `args` list as positional arguments 
 * and the members of the `kwargs` record as keyword arguments. For example,
 *     Odoo.ExecuteKW(connection, "some.model", "a_function", {"arg1", "arg2"}, [kwarg1="kwarg1val", kwarg2="kwarg2val"])
 * executes the following python code in the server
 *     self.env['some.model'].a_function('arg1', 'arg2', kwarg1=kwarg1val, kwarg2, kwarg2val)
 *
 *
 * This function produces an HTTP POST request with roughly the following content:
 *     {"jsonrpc": "2.0",
 *      "method": "call",
 *      "params": {"service": "object",
 *                 "method": "execute_kw",
 *                 "args": [db,
 *                          uid,
 *                          password,
 *                          model,
 *                          function,
 *                          [arg1, arg2],
 *                          {kwarg1: kwarg1val, kwarg2: kwarg2val}},
 *      "id": 135468}
 */
Odoo.ExecuteKW = (connection as record, model as text, function as text, args as list, optional kwargs as record) =>
    let
        _kwargs = if kwargs <> null then kwargs else [],
        result = Odoo.Call(connection, "object", "execute_kw", {model, function, args, _kwargs})
    in
        result;


Odoo._Search = (connection as record, model as text, search_domain as list, optional params as record) =>
    Table.FromRecords(
        Odoo.ExecuteKW(
            connection, 
            model, 
            "search_read", 
            { search_domain }, 
            params
    ));


/* Searches for records based on the `search_domain` (https://www.odoo.com/documentation/master/reference/orm.html#reference-orm-domains)
 * and returns corresponding table. Leave the search_domain as an empty list to return all records.
 *
 * It accepts the following params:
 *    - offset  (int)    = 0
 *    - limit   (int)    = None
 *    - order   (str)    = none
 *    - fields  (list)   = All
 *    - context (record)
 *
 * Example:
 *     Odoo.Search(connection, "account.invoice", {{"state", "=", "paid"}, {"date", ">", "2019-06-15"}}, [fields=["date", "partner_id"]])
 */
Odoo.Search = (connection as record, model as text, optional search_domain as list, 
               optional params as record, optional set_schema as logical) =>
    let
        _search_domain = if search_domain <> null then search_domain else {},
        _set_schema = if set_schema <> null then set_schema else true,
        _params = if params <> null then params else [],

        schema = Odoo.Schema(connection, model, params),

        // If we don't specify which fields we want to read, we only query `store` fields.
        // Also, if the model has one2many fields we first check that we can read the 
        // models which those fields reference. We ignore the fields which reference models we can't read.
        fields = if _params <> []
                 then Record.FieldOrDefault(params, "fields", null)
                 else null,
        o2m_fields = Table.SelectRows(schema, each ([type] = "one2many")),
        models_we_can_read = Odoo.CheckPermissions(connection, o2m_fields[relation]),
        schema2 = if fields = null and _set_schema
                  then Table.SelectRows(
                           schema, 
                           each not ( [type] = "one2many" and 
                                      not List.Contains(models_we_can_read, [relation]) ) and [store] = true )
                  else schema,

        _params2 = if fields = null and _set_schema
                   then _params & [fields=schema2[Name]]
                   else params,

        result = Odoo._Search(connection, model, _search_domain, _params2),


        // We replace false values when they appear in columns which are nullable 
        // and of a type other than logical as they are used to represent null values.
        nullable_non_logical = if Table.ColumnCount(result) = 0 // We check that the table isn't empty so that 
                               then {}                          // we don't try to replace values in inexistent columns
                               else Table.SelectRows(schema2, 
                                                     each Type.IsNullable([Type]) and not Type.Is([Type], 
                                                     type nullable logical))[Name],

        replace_false_with_null = Table.ReplaceValue(result, false, null, Replacer.ReplaceValue, nullable_non_logical),

        // Odoo returns One2Many fields as lists with the format {id, name}.
        // We replace those lists with records [id=id, name=name] so that we can more easily
        // split them into columns.

        list_to_record_map = (x) => if (x <> null) then [id=x{0}, name=x{1}] else null,
        columns_to_map_over = Table.RemoveColumns(
            Table.SelectRows(
                schema2, 
                each ([type] = "many2one")),
            {"type", "relation", "Type", "store"}),
        transform_operations = Table.ToRows(Table.AddColumn(columns_to_map_over, "Transform", each list_to_record_map)),
        with_o2m_as_records = 
            if (List.IsEmpty(transform_operations) or Table.ColumnCount(result) = 0) then
                replace_false_with_null
            else
                Table.TransformColumns(replace_false_with_null, transform_operations),

        
        with_schema = if _set_schema 
                      then Odoo.SetSchema(connection, with_o2m_as_records, schema2) 
                      else result,
        
        reordered_columns = if fields = null
                            then with_schema
                            else Table.ReorderColumns(with_schema, fields)
    in
        reordered_columns;


// Like Odoo.Search but with query folding
Odoo.Search.View = (connection as record, model as text, optional search_domain as list, 
               optional params as record, optional set_schema as logical) =>
    let
        _search_domain = if search_domain <> null then search_domain else {},
        _params = if params <> null then params else [],
        View = (optional sd as list, optional p as record) => Table.View(null, Diagnostics.WrapHandlers([
            GetType = () =>
                // TODO: refactor schema logic
                let
                    newParams = p & [limit=1],
                    result = Value.Type(Odoo.Search(connection, model, sd, newParams, set_schema))
                in
                    result,
            GetRows = () => Odoo.Search(connection, model, sd, p, set_schema),
            OnTake = (count as number) =>
                let
                    currentLimit = Record.FieldOrDefault(p, "limit", false),
                    newLimit = if currentLimit = false then count else List.Min({currentLimit, count}),
                    newParams = p & [ limit = newLimit ]
                in
                    @View(sd, newParams),
            OnSkip = (count as number) =>
                let
                    newParams = p & [ offset = count ]
                in
                    @View(sd, newParams),
            OnSelectColumns = (columns as list) =>
                let
                    newParams = p & [ fields = columns ]
                in
                   @View(sd, newParams),
            OnSort = (order as list) =>
                let
                    // This will convert the list of records to a list of text,
                    // where each entry is "<columnName> <asc|desc>"
                    sorting = List.Transform(order, (o) => 
                        let
                            column = o[Name],
                            order = o[Order],
                            orderText = if (order = Order.Ascending) then "asc" else "desc"
                        in
                            column & " " & orderText
                    ),
                    orderBy = Text.Combine(sorting, ", "),
                    newParams = p & [ order = orderBy ]
                in
                    @View(sd, newParams),
            // OnGroup: https://community.fabric.microsoft.com/t5/Power-Query/Table-View-Handling-NestedJoin-Expand/td-p/2670026, 
            // (keys as { text }, aggregates as {[Name = text, Function = (subtable as table) => any, Type = type]})
            OnGroup = (keys, aggregates) =>
                let

                    logKeys = Diagnostics.LogValue("Keys", keys),
                    logAggregates = Diagnostics.LogValue("Aggregates6", aggregates),
                    fstAggregateFunc = logAggregates{0}[Function],
                    logExpression = Diagnostics.LogValue("Value.Expression(Value.Optimize(fstAggregateFunc))", Value.Expression(Value.Optimize(fstAggregateFunc))),
                    activateLogKeys = if logKeys <> null then true else true,
                    activateLogAggregates = if logExpression <> null then true else true,
                    logAggregatesMetadata = Diagnostics.LogValue("Value.Metadata(logAggregates)", Value.Metadata(logAggregates)),
                    logFstAggregateMetadata = Diagnostics.LogValue("Value.Metadata(logAggregates{0})", Value.Metadata(logAggregates{0})),
                    logFstAggregateFuncMetadata = Diagnostics.LogValue("Value.Metadata(fstAggregateFunc)", Value.Metadata(fstAggregateFunc)),
                    activateLogAggregatesMetadata = if logAggregatesMetadata <> null then true else true,
                    activateLogFstAggregateMetadata = if logFstAggregateMetadata <> null then true else true,
                    activateLogFstAggregateFuncMetadata = if logFstAggregateFuncMetadata <> null then true else true,
                    err = error "Can't actually fold this",
                    result = 
                        if 
                            activateLogKeys and 
                            activateLogAggregates and 
                            activateLogAggregatesMetadata and 
                            activateLogFstAggregateMetadata and 
                            activateLogFstAggregateFuncMetadata 
                        then err else err
                in
                    logAggregates,
            // OnSelectRows: https://github.com/Ihor-UHP/DataConnectors/blob/master/docs/table-view.md
            // OnInvoke: https://bengribaudo.com/blog/2022/01/04/6398/custom-folding-arbitrary-functions-oninvoke-table-viewfunction
            GetRowCount = () => 
                let
                    limit = Record.FieldOrDefault(_params, "limit", null),
                    result = Odoo.SearchCount(connection, model, _search_domain, limit)
                in
                    result
        ])),

        getFunctionName = (f as function) => Value.Metadata(Value.Type(f))[Documentation.Name],
        getAggregateDefinition = (aggregate as record) =>
            let 
                expression = aggregate[Function][Expression],
                isAllColumns = if expression = [Kind = "Identifier", Name = "_", IsInclusive = true] then true else false, // when the aggregate function is `each _`
                isAllColumnsResult = [ 
                    Name = aggregate[Name],
                    Function = "_", 
                    Arguments = {},
                    Type = aggregate[Type]
                ],
                isFunction = expression[Kind] = "Invocation",
                isFunctionResult = [ 
                    Name = aggregate[Name],
                    Function = getFunctionName(expression[Function][Value]), 
                    Arguments = expression[Arguments],
                    Type = aggregate[Type]
                ]
            in
                if isAllColumns then isAllColumnsResult else 
                if isFunction   then isFunctionResult else
                error "Unsupported aggregation kind."
    in
        View(_search_domain, _params);
    


/*  Checks whether a user has a certain permission over a list of models.
 *  Returns the subset of `models` that the user indicated by `uid` has `permission` permission on.
 *  By default `permission` = "read" and `uid` = `connection[uid]`
 */
Odoo.CheckPermissions = (connection as record, models as list, optional uid as number, optional permission as text) =>
    let
        _uid = if uid <> null then uid else connection[uid],
        _permission = if permission <> null then permission else "read",
        permission_field = "perm_" & _permission,
        models_with_perm = Odoo.ReadGroup(
            connection, 
            "ir.model.access", 
            { {permission_field, "=", true},
              {"model_id.model", "in", models},
              "|", {"group_id.users", "=", _uid}, {"group_id", "=", false} },
            {},
            {"model_id"}),
        ids = List.Transform(models_with_perm[model_id], List.First),
        // TODO: cache 'ir.model' globally to avoid this call
        model_names = if List.Count(models) <> 0 // Shortcut
                      then Odoo._Search(connection, "ir.model", {{"id", "in", ids}}, [fields={"model"}])[model]
                      else {}
    in
        model_names;


Odoo.ReadGroup = (
    connection as record, 
    model as text, 
    search_domain as list, 
    fields as list, 
    groupby as list, 
    optional offset as nullable number, 
    optional limit as nullable number, 
    optional orderby as nullable text, 
    optional lazy as logical) =>
    let
        _lazy = if lazy <> null then lazy else false, // Odoo's default value is lazy = True. I don't think it makes sense to do that in PBI.
        params = [ fields=fields, groupby=groupby, lazy=_lazy ],
        params2 = if offset  = null then params  else params  & [ offset  = offset  ],
        params3 = if limit   = null then params2 else params2 & [ limit   = limit   ],
        params4 = if orderby = null then params3 else params3 & [ orderby = orderby ],
        result = Table.FromRecords(Odoo.ExecuteKW(connection, model, "read_group", {search_domain}, params)),
        without_domain = Table.RemoveColumns(result,{"__domain"})
    in
        without_domain;


Odoo.FieldsGet = (connection as record, model as text, optional fields as nullable list, optional attributes as nullable list) as record =>
    Odoo.ExecuteKW(connection, model, "fields_get", {fields, attributes});


Odoo.TypeTranslations = [
    boolean = type logical,
    char = type text,
    #"text" = type text,
    float = Decimal.Type,
    integer = Int64.Type,
    #"binary" = type binary,
    image = type binary,
    monetary = Currency.Type,
    #"date" = type date,
    #"datetime" = type datetime,
    many2one = type list,
    one2many = type record,
    many2many = type list,
    selection = type text
];


Odoo.TranslateType = (OdooType as text, required as nullable logical) =>
    let
        _MLanguageType = Record.FieldOrDefault(Odoo.TypeTranslations, OdooType, type any),
        _required = if required <> null
                    then required
                    else false,
        MLanguageType  = if _required then _MLanguageType else type nullable _MLanguageType
    in
        MLanguageType;


Odoo._Schema = (connection as record, model as text, optional fields as nullable list) as table =>
    let 
        fields_details = Odoo.FieldsGet(connection, model, fields, {"type", "required", "relation", "store"}),
        fields_details_table = Table.ExpandRecordColumn(Record.ToTable(fields_details), "Value", {"required", "type", "relation", "store"}),

        with_type = Table.AddColumn(fields_details_table, "Type", each Odoo.TranslateType([type], [required])),
        removed_cols = Table.RemoveColumns(with_type, {"required"})
    in
        removed_cols;


Odoo.Schema = (connection as record, model as text, optional params as nullable record) as table =>
    let
        fields = if params <> null
                 then Record.FieldOrDefault(params, "fields", null)
                 else null,
        schema = Odoo._Schema(connection, model, fields)
    in 
        schema;


Odoo.SetSchema = (connection as record, table as table, schema as table, optional enforceSchema as number) as table =>
    let
        _enforceSchema = if enforceSchema <> null then enforceSchema else EnforceSchema.IgnoreExtraColumns,
        only_PBI_schema = Table.SelectColumns(schema, {"Name", "Type"}), // Just the columns relevant to the PowerBI schema
        with_schema = SchemaTransformTable(table, only_PBI_schema, _enforceSchema)
    in
        with_schema;

/* Searches for records based on the `search_domain` (https://www.odoo.com/documentation/master/reference/orm.html#reference-orm-domains)
 * and returns the number it found. Leave the search_domain as an empty list to count all records.
 *
 * Example:
 *     Odoo.SearchCount(connection, "account.invoice", {{"state", "=", "paid"}, {"date", ">", "2019-06-15"}}, 10)
 */
Odoo.SearchCount = (connection as record, model as text, optional search_domain as list, 
               optional limit as nullable number) =>
    let
        _search_domain = if search_domain <> null then search_domain else {},
        params = if limit <> null then [limit = Number.Round(limit, 0, RoundingMode.Down)] else [],
        result = Odoo.ExecuteKW(
            connection, 
            model, 
            "search_count", 
            { _search_domain }, 
            params
        )

    in
        result;

SearchCountType = type function (
    model as (type text meta [
        Documentation.FieldCaption = "Model",
        Documentation.FieldDescription = "Technical name of the model to query",
        Documentation.SampleValues = {"res.partner", "account.invoice"}
    ]),
    optional search_domain as (type nullable list meta [
        Documentation.FieldCaption = "Search domain",
        Documentation.FieldDescription = "See https://www.odoo.com/documentation/master/reference/orm.html#reference-orm-domains",
        Documentation.SampleValues = {"{{""name"", ""ilike"", ""dave""}, {""customer"", ""="", true}}", "account.invoice"},
        Formatting.IsMultiLine = true,
        Formatting.IsCode = true
    ]),
    optional limit as (type nullable number meta [
        Documentation.FieldCaption = "Limit ",
        Documentation.FieldDescription = "Maximum number of record to count (upperbound). Defaults to all",
        Documentation.SampleValues = {"10", "null"},
        Formatting.IsMultiLine = false,
        Formatting.IsCode = false
    ]))
    as table meta [
        Documentation.Name = "search_count",
        Documentation.LongDescription = "Counts the number of records of a given model which satisfy a given search_domain. See https://www.odoo.com/documentation/18.0/developer/reference/backend/orm.html#odoo.models.Model.search_count",
        Documentation.Examples = {[
            Description = "Get the number of products we sell.",
            Code = 
"search_count(
    ""product.template"", 
    { {""sale_ok"", ""="", true} }
)",
            Result = "100"
        ]}
    ];

SearchReadType = type function (
    model as (type text meta [
        Documentation.FieldCaption = "Model",
        Documentation.FieldDescription = "Technical name of the model to query",
        Documentation.SampleValues = {"res.partner", "account.invoice"}
    ]),
    optional search_domain as (type nullable list meta [
        Documentation.FieldCaption = "Search domain",
        Documentation.FieldDescription = "See https://www.odoo.com/documentation/master/reference/orm.html#reference-orm-domains",
        Documentation.SampleValues = {"{{""name"", ""ilike"", ""dave""}, {""customer"", ""="", true}}", "account.invoice"},
        Formatting.IsMultiLine = true,
        Formatting.IsCode = true
    ]),
    optional params as (type nullable record meta [
        Documentation.FieldCaption = "Keyword parameters",
        Documentation.FieldDescription = "Record containing parameters to be passed as keywords to 'search_read'. Can include: offset, limit, order, fields, context.",
        Documentation.SampleValues = {"[limit=10, fields={""name"", ""state_id"", ""country_id""}, order=""name""]"},
        Formatting.IsMultiLine = true,
        Formatting.IsCode = true
    ]),
    optional set_schema as (type logical meta [
        Documentation.FieldCaption = "Set schema?",
        Documentation.FieldDescription = "Wheter or not to automatically set the resulting table's schema according to the Odoo fields' definitions. Default: true.",
        Documentation.SampleValues = {"true", "false"},
        Documentation.AllowedValues = {true, false}
    ]))
    as table meta [
        Documentation.Name = "search_read",
        Documentation.LongDescription = "Queries an Odoo model. See https://www.odoo.com/documentation/18.0/developer/reference/external_api.html?highlight=search_read#search-and-read",
        Documentation.Examples = {[
            Description = "Get the names and emails of our contacts at Azure Interior.",
            Code = 
"search_read(
    ""res.partner"", 
    { {""parent_name"", ""="", ""Azure Interior""} }, 
    [ fields={""name"", ""email""} ]
)",
            Result = 
"Table.FromRecords({
    [email = ""brandon.freeman55@example.com"", name = ""Brandon Freeman"", id = 26],
    [email = ""colleen.diaz83@example.com"",    name = ""Colleen Diaz"",    id = 33],
    [email = ""nicole.ford75@example.com"",     name = ""Nicole Ford"",     id = 27]
})"
        ]}
    ];

Odoo.CreateFunctionsNavTable = (connection as record) =>
    let
        searchReadImpl = (model as text, optional search_domain as nullable list, optional params as nullable record, optional set_schema as logical) =>
            Odoo.Search.View(connection, model, search_domain, params, set_schema),
        search_read = Value.ReplaceType(searchReadImpl, SearchReadType),
        
        searchCountImpl = (model as text, optional search_domain as nullable list, optional limit as nullable number) =>
            Odoo.SearchCount(connection, model, search_domain, limit),
        search_count = Value.ReplaceType(searchCountImpl, SearchCountType),

        read_group = (
            model as text,
            search_domain as list, 
            fields as list, 
            groupby as list, 
            optional offset as nullable number, 
            optional limit as nullable number, 
            optional orderby as nullable text, 
            optional lazy as logical 
        ) => Odoo.ReadGroup(connection, model, search_domain, fields, groupby, offset, limit, orderby, lazy),


        fun_table =
            #table(
                {    "Function"    , "Name"        , "Data"      , "ItemKind", "IsLeaf"  }, 
                {
                    {"search_read" , "search_read" , search_read , "Function", "Function"},
                    {"search_count", "search_count", search_count, "Function", "Function"},
                    {"read_group"  , "read_group"  , read_group  , "Function", "Function"}
                }
            ),
        navTable = Table.ToNavigationTable(fun_table, {"Function"}, "Name", "Data", "ItemKind", "ItemKind", "IsLeaf")
    in
        navTable;


Odoo.CreateModelsNavTable = (connection as record) =>
    let
        models = Odoo.Search(connection, "ir.model", {{"transient", "=", false}}, [fields={"model", "name"}, order="model"]), 
        models_table = 
            #table({"Model", "Name", "Data", "ItemKind", "IsLeaf"}, 
                Table.TransformRows(models, each {
                    [model], 
                    [name] & " (" & [model] & ")", 
                    Table.GenerateContainerLeaf([model], [name],  Odoo.Search.View(connection, [model], {}, [])),
                    "Table",
                    false
                })
            ),
        navTable = Table.ToNavigationTable(models_table, {"Model"}, "Name", "Data", "ItemKind", "ItemKind", "IsLeaf")
    in
        navTable;


Odoo.CreateNavTable = (connection as record) =>
    let
        master_table =
            #table(
                { "Key",       "Name",      "Data",                                   "ItemKind", "IsLeaf"}, 
                {{"Functions", "Functions", Odoo.CreateFunctionsNavTable(connection), "Function", false},
                 {"Tables",    "Tables",    Odoo.CreateModelsNavTable(connection),    "Table",    false}}
            ),
        navTable = Table.ToNavigationTable(master_table, {"Key"}, "Name", "Data", "ItemKind", "ItemKind", "IsLeaf")
    in
        navTable;
