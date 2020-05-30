// This file contains your Data Connector logic
section Odoo;

[DataSource.Kind="Odoo", Publish="Odoo.Publish"]
shared Odoo.Contents = (URL as text, Database as text) =>
    let
        /*connection = Odoo.Login(url, db, username, password),*/
        credential = Extension.CurrentCredential(),
        connection = Odoo.Login(URL, Database, credential[Username], credential[Password]),
        partners = Table.FromRecords(Odoo.Call(connection, "object", "execute", {"res.partner", "search_read", {}, {"name"}})),
        invoices = 
            Table.FromRecords(Odoo.ExecuteKW(connection, "account.invoice", "search_read", 
                {{{"state", "=", "paid"}}}, 
                [
                    limit = 5,
                    fields={"date_invoice", "partner_id", "display_name", "amount_total_signed", "state"}
                ]
            ))
    in
        invoices;


// Data Source Kind description
Odoo = [
    Authentication = [
        // Key = [],
        UsernamePassword = []
        // Windows = [],
        //Implicit = []
    ],
    Label = Extension.LoadString("DataSourceLabel")
];


// Data Source UI publishing description
Odoo.Publish = [
    Beta = true,
    Category = "Other",
    ButtonText = { Extension.LoadString("ButtonTitle"), Extension.LoadString("ButtonHelp") },
    LearnMoreUrl = "https://powerbi.microsoft.com/",
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


// Returns user id
Odoo.Login = (url as text, db as text, username as text, password as text) as record =>
    let 
        jsonrpc_url = url & "/jsonrpc",
        uid = JsonRpc.Call(jsonrpc_url, "common", "login", { db, username, password }),
        connection = 
            if uid = false then
                error "Odoo authentication error"
            else
                [
                    url = jsonrpc_url,
                    db = db,
                    uid = uid,
                    password = password
                ]
    in
        connection;

shared Odoo.Call = (connection as record, service as text, method as text, args as list) =>
    JsonRpc.Call(
        connection[url], 
        service, 
        method, 
        {
            connection[db], 
            connection[uid],
            connection[password]
        } & args
    );

// TODO: Make kwargs optional
shared Odoo.ExecuteKW = (connection as record, model as text, method as text, args as list, kwargs as record) =>
    Odoo.Call(connection, "object", "execute_kw", {model, method, args, kwargs});


/**************************************************
 ******************** JSON-RPC ********************
 **************************************************/

// Adapted from https://www.odoo.com/documentation/12.0/howtos/backend.html#json-rpc-library
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
                ]
            else
                response[result]
    in
        result;

JsonRpc.Call = (url as text, service as text, method as text, args) =>
    JsonRpc.Request(url, "call", [service=service, method=method, args=args]);
