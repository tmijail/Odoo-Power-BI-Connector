# Odoo - Power BI Connector

This project allows Power BI to query data from Odoo through the JsonRPC API. 

Before this connector, the only way to query Odoo from Power BI was to connect directly to the PostreSQL database. This is impossible if, for example, the Odoo instance is hosted on odoo.sh or on some other platform which doesn't expose the database to the internet.

## Install
1. Create a `%USERPROFILE%\Documents\Power BI Desktop\Custom Connectors` directory.
2. Copy `Odoo.mez` into that directory.
3. Open Power BI Desktop and enable loading unsigned connectors (*File > Options and settings > Options > Security > Data Extensions > Allow any extension to load without warning or validation*)
4. Restart Power BI Desktop

## Use

Currently a big limitation of this connector is that it doesn't support query folding. This means that if you load a table and filter it through the Query Editor UI, Power BI will download the whole table and then filter it locally instead of sending the search context to the server and downloading just the needed columns and rows. This is inefficient at best and can lead to an `Odoo Server Error: Out of memory exception` at worst.

Because of this, the current recommended way to get data is through the `#"Custom query"` function.

![Demonstration](usage.gif)

### Custom query

`#"Custom query"` is analogous to Odoo's `search_read` function. 

```M
#"Custom query"(
    model as text, 
    optional search_domain as list, 
    optional params as record, 
    optional set_schema as bool
)
```

Where:

 - `model`: Technical name of the model to query. *Examples: "res.partner", "account.invoice"*.

 - `search_domain`: An Odoo [Search Domain](https://www.odoo.com/documentation/14.0/reference/orm.html#reference-orm-domains). 
 
    It's important to remember that lists in the M Language are enclosed in cuvy brackets (`{...}`). So the following python search domain

    ```python
    [('name','=','ABC'),
    ('language.code','!=','en_US'),
    '|',('country_id.code','=','be'),
        ('country_id.code','=','de')]
    ```
    should be written in M like

    ```M
    {{"name","=","ABC"},
    {"language.code","!=","en_US"},
    "|",{"country_id.code","=","be"},
        {"country_id.code","=","de"}}
    ```

 - `params`: A record containing any keyword parameter that we want to pass to `search_read`. Can include:

   - `offset as Int64.Type`
   - `limit as Int64.Type`
   - `order as text`
   - `fields as list`
   - `context as record`

 - `set_schema`: Whether or not to set the column types according to the field definition on Odoo. Defaults to `true`.

#### Example: Get the names and emails of our contacts at Azure Interior

```M
#"Custom query"(
    "res.partner",
    { {"parent_name", "=", "Azure Interior"} },
    [ fields = {"name", "email"}, order = "name" ]
)
```

| email                         | name            | id |
| ----------------------------- | --------------- | -- |
| brandon.freeman55@example.com | Brandon Freeman | 26 |
| colleen.diaz83@example.com    | Colleen Diaz    | 33 |
| nicole.ford75@example.com     | Nicole Ford     | 27 |


## Build
1. Install Visual Studio
2. Install the [Power Query SDK](https://marketplace.visualstudio.com/items?itemName=Dakahn.PowerQuerySDK)
3. Clone this repository and open `Odoo.sln`
4. *Optional:* Install and configure the [Auto Deploy](https://marketplace.visualstudio.com/items?itemName=lennyomg.AutoDeploy) extension to copy `Odoo.mez` to `%USERPROFILE%\Documents\Power BI Desktop\Custom Connectors` after every build.
5. Compile (*Build > Build Solution / Ctrl+Shift+B*)

## Tests
Unit tests can be executed by pressing *Start* on the Visual Studio toolbar or by pressing *F5*. 

By default the unit tests assume there's a non-empty Odoo instance running at http://localhost:8069 with a database named `db`. A `docker-compose.yml` file is provided to easily set up such an instance. Just execute `docker-compose up`, wait a bit, go to http://localhost:8069 and set up the database with sample data.

If you want to use some other server for the tests, simply edit `test-server.json`.