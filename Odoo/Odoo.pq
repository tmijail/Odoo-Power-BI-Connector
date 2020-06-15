[Version = "0.0.1"]
section Odoo;

[DataSource.Kind="Odoo", Publish="Odoo.Publish"]
shared Odoo.Contents = (URL as text, Database as text) =>
    let
        connection = Odoo.Login(URL, Database),
        navTable = Odoo.CreateModelsNavTable(connection)
    in
        navTable;


// Data Source Kind description
Odoo = [
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
     JsonRpc.Call(url & "/jsonrpc", "db", "list", {});

// Finds the uid of the Odoo User.
 Odoo.GetUID = (url as text, db as text) as number =>
     let 
        credentials = Extension.CurrentCredential(),
        jsonrpc_url = url & "/jsonrpc",
        uid = JsonRpc.Call(jsonrpc_url, "common", "login", { db, credentials[Username], credentials[Password] }),
        result = if uid = false then error "Odoo authentication error" else uid
    in
        result;

// Finds the uid of the Odoo User and saves all the information needed to connect to the db in the `connection` record.
Odoo.Login = (url as text, db as text) as record =>
    let
        uid = Odoo.GetUID(url, db),
        connection = [url = url & "/jsonrpc",
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
        _connection = if Record.HasFields(connection, "uid") then connection else Odoo.Login(connection[url], connection[db]),
        result = JsonRpc.Call(_connection[url], service, method, {_connection[db], _connection[uid], Extension.CurrentCredential()[Password]} & args)
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
shared Odoo.ExecuteKW = (connection as record, model as text, function as text, args as list, optional kwargs as record) =>
    let
        _kwargs = if kwargs <> null then kwargs else [],
        result = Odoo.Call(connection, "object", "execute_kw", {model, function, args, _kwargs})
    in
        result;


/* Searches for records based on the `search_domain` (https://www.odoo.com/documentation/13.0/reference/orm.html#reference-orm-domains)
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
shared Odoo.Search = (connection as record, model as text, optional search_domain as list, 
                      optional params as record, optional set_schema as logical) =>
    let
        _search_domain = if search_domain <> null then search_domain else {},
        _set_schema = if set_schema <> null then set_schema else true,
        result = Table.FromRecords(Odoo.ExecuteKW(connection, model, "search_read", 
            {_search_domain}, 
            params
        )),
        with_schema = if _set_schema then Odoo.SetSchema(connection, model, result) else result
    in
        with_schema;


Odoo.Schema = (connection as record, model as text, optional fields as list) as table =>
    let
        search_domain_base = {{"model", "=", model}},
        search_domain = if fields = null then search_domain_base else search_domain_base & {{"name", "in", fields}},
        fields_details = Odoo.Search(connection, "ir.model.fields", search_domain, [fields={"name", "ttype", "required"}], false),
        with_type = Table.AddColumn(fields_details, "Type", each Odoo.TranslateType([ttype], [required])),
        removed_cols = Table.RemoveColumns(with_type, {"required", "id", "ttype"}),
        renamed_cols = Table.RenameColumns(removed_cols, {{"name", "Name"}})
    in
        renamed_cols;

Odoo.SetSchema = (connection as record, model as text, table as table, optional enforceSchema as number) as table =>
    let
        _enforceSchema = if enforceSchema <> null then enforceSchema else 3,
        fields = Table.ColumnNames(table),
        schema = Odoo.Schema(connection, model, fields),
        with_schema = SchemaTransformTable(table, schema, _enforceSchema)
    in
        with_schema;

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
    one2many = type list,
    many2many = type list
];


Odoo.TranslateType = (OdooType as text, required as logical) =>
    let
        _MLanguageType = Record.FieldOrDefault(Odoo.TypeTranslations, OdooType, type any),
        MLanguageType  = if required then _MLanguageType else type nullable _MLanguageType
    in
        MLanguageType;


Odoo.CreateModelsNavTable = (connection as record) =>
    let
        models = Odoo.Search(connection, "ir.model", {{"transient", "=", false}}, [fields={"model", "name"}, order="model"]), 
        customQuery = (model as text, optional search_domain as nullable list, optional params as nullable record) =>
            Odoo.Search(connection, model, search_domain, params),
        models_table = 
            #table({"model", "name", "data", "itemKind", "isLeaf"}, 
                {{"customQuery", "Custom query", customQuery, "Function", "Function"}} & 
                Table.TransformRows(models, each {
                    [model], 
                    [name] & " (" & [model] & ")", 
                    Table.GenerateContainerLeaf([model], [name],  Odoo.Search(connection, [model], {}, [])),
                    "Table",
                    false
                })
            ),
        navTable = Table.ToNavigationTable(models_table, {"model"}, "name", "data", "itemKind", "itemKind", "isLeaf")
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
        raw_response = Web.Contents(url, [ Content = data, Headers = [#"Content-Type" = "application/json"] ]),
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