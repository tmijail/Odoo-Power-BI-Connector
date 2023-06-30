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


/************************************************
 ******************* Includes *******************
 ************************************************/


Extension.LoadFunction = (name as text) =>
    let
        binary = Extension.Contents(name),
        asText = Text.FromBinary(binary)
    in
        Expression.Evaluate(asText, #shared);

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
            if (List.IsEmpty(transform_operations) or Table.ColumnCount(result) = 0) then
                replace_false_with_null
            else
                Table.TransformColumns(replace_false_with_null, transform_operations),

        
        with_schema = if _set_schema 
                      then Odoo.SetSchema(connection, with_o2m_as_records, schema2) 
                      else result
    in
        with_schema;


// Like Odoo.Search but with query folding
Odoo.Search.View = (connection as record, model as text, optional search_domain as list, 
               optional params as record, optional set_schema as logical) =>
    Table.View(null, [
        GetType = () => Value.Type(GetRows()),
        GetRows = () => Odoo.Search(connection, model, search_domain, params, set_schema)
    ]);


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
        _enforceSchema = if enforceSchema <> null then enforceSchema else EnforceSchema.IgnoreExtraColumns,
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
            Odoo.Search.View(connection, model, search_domain, params, set_schema),
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
