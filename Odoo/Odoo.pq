// This file contains your Data Connector logic
section Odoo;

[DataSource.Kind="Odoo", Publish="Odoo.Publish"]
shared Odoo.Contents = (URL as text, Database as text) =>
    let
        connection = Odoo.Login(URL, Database),
        navTable = Odoo.CreateNavTable(connection)
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


// Finds the uid of the Odoo User and saves all the information needed to connect to the db in the `connection` record.
Odoo.Login = (url as text, db as text) as record =>
    let 
        credentials = Extension.CurrentCredential(),
        jsonrpc_url = url & "/jsonrpc",
        uid = JsonRpc.Call(jsonrpc_url, "common", "login", { db, credentials[Username], credentials[Password] }),
        connection = 
            if uid = false then
                error "Odoo authentication error"
            else
                [
                    url = jsonrpc_url,
                    db = db,
                    uid = uid
                ]
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
shared Odoo.Call = (connection as record, service as text, method as text, args as list) =>
    JsonRpc.Call(connection[url], service, method, {connection[db], connection[uid], Extension.CurrentCredential()[Password]} & args);


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
shared Odoo.Search = (connection as record, model as text, search_domain as list, 
                      optional params as record) =>
    let
        _search_domain = if search_domain <> null then search_domain else {},
        result = Table.FromRecords(Odoo.ExecuteKW(connection, model, "search_read", 
            {_search_domain}, 
            params
        ))
    in
        result;


Odoo.CreateNavTable = (connection as record) =>
    let
        models = Odoo.Search(connection, "ir.model", {{"abstract", "=", false}, {"transient", "=", false}}, [fields={"model", "name"}, order="model"]), 
        models_table = 
            #table({"model", "name", "data", "itemKind", "isLeaf"}, 
                Table.TransformRows(models, each {
                    [model], 
                    [name] & " (" & [model] & ")", 
                    Table.GenerateContainerLeaf([model], [name],  Odoo.Search(connection, [model], {}, [fields={"name"}])),
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
                    /*
                    Reason = response[#"error"][message], 
                    Message = try response[#"error"][data][message] otherwise "JSON-RPC Error", 
                    Detail = try response[#"error"][data][debug] otherwise Lines.FromBinary(raw_response,null,null,1252){0}
                    */
                    Reason = try response[#"error"][message] & " (" & response[#"error"][data][message] & ")" otherwise response[#"error"][message], 
                    Message = Lines.FromBinary(raw_response,null,null,1252){0}, 
                    Detail = ""
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