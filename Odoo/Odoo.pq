[Version = "0.1.0"]
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
        uid = Odoo.GetUID(url, db),
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

        // If we don't specify which fields we want to read and the model has one2many fields
        // we first check that we can read the models which those fields reference.
        // We ignore the fields which reference models we can't read.
        fields = if _params <> []
                 then Record.FieldOrDefault(params, "fields", null)
                 else null,
        o2m_fields = Table.SelectRows(schema, each ([type] = "one2many")),
        models_we_can_read = Odoo.CheckPermissions(connection, o2m_fields[relation]),
        schema2 = if fields = null and _set_schema
                  then Table.SelectRows(
                           schema, 
                           each not ( [type] = "one2many" and 
                                      not List.Contains(models_we_can_read, [relation]) ))
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
            Table.SelectRows(schema2, each ([type] = "many2one")),
            {"type", "relation", "Type"}),
        transform_operations = Table.ToRows(Table.AddColumn(columns_to_map_over, "Transform", each list_to_record_map)),
        with_o2m_as_records = 
            if (List.IsEmpty(transform_operations)) then
                replace_false_with_null
            else
                Table.TransformColumns(replace_false_with_null, transform_operations),

        
        with_schema = if _set_schema 
                      then Odoo.SetSchema(connection, with_o2m_as_records, schema2) 
                      else result
    in
        with_schema;


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
              {"group_id.users", "child_of", _uid} },
            {},
            {"model_id"}),
        ids = List.Transform(models_with_perm[model_id], List.First),
        model_names = if List.Count(models) <> 0 // Shortcut
                      then Odoo._Search(connection, "ir.model", {{"id", "in", ids}}, [fields={"model"}])[model]
                      else {}
    in
        model_names;


Odoo.ReadGroup = (connection as record, model as text, search_domain as list, fields as list, groupby as list, optional lazy as logical) =>
    let
        _lazy = if lazy <> null then lazy else false,
        result = Table.FromRecords(Odoo.ExecuteKW(connection, model, "read_group", {search_domain}, [fields=fields, groupby=groupby, lazy=_lazy])),
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
    many2many = type list
];


Odoo.TranslateType = (OdooType as text, required as logical) =>
    let
        _MLanguageType = Record.FieldOrDefault(Odoo.TypeTranslations, OdooType, type any),
        MLanguageType  = if required then _MLanguageType else type nullable _MLanguageType
    in
        MLanguageType;


Odoo._Schema = (connection as record, model as text, optional fields as nullable list) as table =>
    let 
        fields_details = Odoo.FieldsGet(connection, model, fields, {"type", "required", "relation"}),
        fields_details_table = Table.ExpandRecordColumn(Record.ToTable(fields_details), "Value", {"required", "type", "relation"}),

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
        _enforceSchema = if enforceSchema <> null then enforceSchema else 2,
        only_PBI_schema = Table.SelectColumns(schema, {"Name", "Type"}), // Just the columns relevant to the PowerBI schema
        with_schema = SchemaTransformTable(table, only_PBI_schema, _enforceSchema)
    in
        with_schema;


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
        Documentation.LongDescription = "Queries an Odoo model. See https://www.odoo.com/documentation/master/webservices/odoo.html#search-and-read",
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
        customQueryImpl = (model as text, optional search_domain as nullable list, optional params as nullable record, optional set_schema as logical) =>
            Odoo.Search(connection, model, search_domain, params, set_schema),
        search_read = Value.ReplaceType(customQueryImpl, SearchReadType),
        fun_table =
            #table(
                { "Function",    "Name",        "Data",      "ItemKind", "IsLeaf"}, 
                {{"search_read", "search_read", search_read, "Function", "Function"}}
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
                    Table.GenerateContainerLeaf([model], [name],  Odoo.Search(connection, [model], {}, [])),
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


/**************************************************
 ******************** JSON-RPC ********************
 **************************************************/

/* Adapted from https://www.odoo.com/documentation/12.0/howtos/backend.html#json-rpc-library
 *
 * {"jsonrpc": "2.0",
 *  "method": method,
 *  "params": params,
 *  "id": 135468}
 */
JsonRpc.Request = ( url as text, method as text, params as record ) =>
    let
        data = Json.FromValue([
            jsonrpc = "2.0",
            method = method,
            params = params,
            id = Number.RoundDown(Number.RandomBetween(0, 1000000000))
        ]),
        raw_response = Web.Contents(url, [ Content = data, Headers = [#"Content-Type" = "application/json"], Timeout = #duration(0, 0, 15, 0) ]),
        response = Json.Document(raw_response),
        result = 
            if Record.HasFields(response, "error") then
                error [
                    
                    Reason = response[#"error"][message], 
                    Message = try response[#"error"][data][message] otherwise "JSON-RPC Error", 
                    Detail = try response[#"error"][data][debug] otherwise Lines.FromBinary(raw_response,null,null,1252){0}
                    /*
                    Reason = try response[#"error"][message] & " (" & response[#"error"][data][message] & ")" otherwise response[#"error"][message], 
                    Message = Lines.FromBinary(raw_response,null,null,1252){0}, 
                    Detail = ""
                    */
                ]
            else
                response[result]
    in
        result;


/* {"jsonrpc": "2.0",
 *  "method": "call",
 *  "params": {"service": service,
 *             "method": method,
 *             "args": args},
 *  "id": 135468}
 */
JsonRpc.Call = (url as text, service as text, method as text, args) =>
    JsonRpc.Request(url, "call", [service=service, method=method, args=args]);


/****************************************************
 ******************** Nav Tables ********************
 ****************************************************/


Table.ToNavigationTable = (
    table as table,
    keyColumns as list,
    nameColumn as text,
    dataColumn as text,
    itemKindColumn as text,
    itemNameColumn as text,
    isLeafColumn as text
) as table =>
    let
        tableType = Value.Type(table),
        newTableType = Type.AddTableKey(tableType, keyColumns, true) meta 
        [
            NavigationTable.NameColumn = nameColumn, 
            NavigationTable.DataColumn = dataColumn,
            NavigationTable.ItemKindColumn = itemKindColumn, 
            Preview.DelayColumn = itemNameColumn, 
            NavigationTable.IsLeafColumn = isLeafColumn
        ],
        navigationTable = Value.ReplaceType(table, newTableType)
    in
        navigationTable;


// Makes a navtable with a single entry
Table.GenerateContainerLeaf = (Key as text, Name as text, Data, optional ItemKind as text, optional ItemName as text) as table => 
    let
        _ItemKind = if ItemKind <> null then ItemKind else "Table",
        _ItemName = if ItemName <> null then ItemName else _ItemKind,
        Table = #table({"Key", "Name", "Data", "ItemKind", "ItemName", "IsLeaf"}, {{Key, Name, Data, _ItemKind, _ItemName, true}}),
        NavTable = Table.ToNavigationTable(Table, {"Key"}, "Name", "Data", "ItemKind", "ItemName", "IsLeaf")
    in
        NavTable;


/************************************************
 ******************** Schema ********************
 ************************************************/


EnforceSchema.Strict = 1;               // Add any missing columns, remove extra columns, set table type
EnforceSchema.IgnoreExtraColumns = 2;   // Add missing columns, do not remove extra columns
EnforceSchema.IgnoreMissingColumns = 3; // Do not add or remove columns

SchemaTransformTable = (table as table, schema as table, optional enforceSchema as number) as table =>
    let
        // Default to EnforceSchema.Strict
        _enforceSchema = if (enforceSchema <> null) then enforceSchema else EnforceSchema.Strict,

        // Applies type transforms to a given table
        EnforceTypes = (table as table, schema as table) as table =>
            let
                map = (t) => if Type.Is(t, type list) or Type.Is(t, type record) or t = type any then null else t,
                mapped = Table.TransformColumns(schema, {"Type", map}),
                omitted = Table.SelectRows(mapped, each [Type] <> null),
                existingColumns = Table.ColumnNames(table),
                removeMissing = Table.SelectRows(omitted, each List.Contains(existingColumns, [Name])),
                primativeTransforms = Table.ToRows(removeMissing),
                changedPrimatives = Table.TransformColumnTypes(table, primativeTransforms)
            in
                changedPrimatives,

        // Returns the table type for a given schema
        SchemaToTableType = (schema as table) as type =>
            let
                toList = List.Transform(schema[Type], (t) => [Type=t, Optional=false]),
                toRecord = Record.FromList(toList, schema[Name]),
                toType = Type.ForRecord(toRecord, false)
            in
                type table (toType),

        // Determine if we have extra/missing columns.
        // The enforceSchema parameter determines what we do about them.
        schemaNames = schema[Name],
        foundNames = Table.ColumnNames(table),
        addNames = List.RemoveItems(schemaNames, foundNames),
        extraNames = List.RemoveItems(foundNames, schemaNames),
        tmp = Text.NewGuid(),
        added = Table.AddColumn(table, tmp, each []),
        expanded = Table.ExpandRecordColumn(added, tmp, addNames),
        result = if List.IsEmpty(addNames) then table else expanded,
        fullList =
            if (_enforceSchema = EnforceSchema.Strict) then
                schemaNames
            else if (_enforceSchema = EnforceSchema.IgnoreMissingColumns) then
                foundNames
            else
                schemaNames & extraNames,

        // Select the final list of columns.
        // These will be ordered according to the schema table.
        reordered = Table.SelectColumns(result, fullList, MissingField.Ignore),
        enforcedTypes = EnforceTypes(reordered, schema),
        withType = if (_enforceSchema = EnforceSchema.Strict) then Value.ReplaceType(enforcedTypes, SchemaToTableType(schema)) else enforcedTypes
    in
        withType;