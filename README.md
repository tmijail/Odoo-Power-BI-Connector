# Odoo - Power BI Connector

This project allows Power BI to query data from Odoo through the JsonRPC API. 

Before this connector, the only way to query Odoo from Power BI was to connect directly to the PostreSQL database. This is impossible if, for example, the Odoo instance is hosted on odoo.sh or on some other platform which doesn't expose the database to the internet.

## Installation
1. Create a `[Documents]\Power BI Desktop\Custom Connectors` directory.
2. Download [Odoo.mez](https://github.com/tmijail/Odoo-Power-BI-Connector/releases) and place it in that directory.
3. Open Power BI Desktop and enable loading unsigned connectors (*File > Options and settings > Options > Security > Data Extensions > Allow any extension to load without warning or validation*)
4. Restart Power BI Desktop

Read the [PBI documentation](https://learn.microsoft.com/power-bi/connect-data/desktop-connector-extensibility#data-extension-security) if you have any trouble.

## Usage

Currently a big limitation of this connector is that it doesn't support query folding. This means that if you load a table and filter it through the Power Query Editor UI, Power BI will download the whole table and then filter it locally instead of sending the filter definition to the server and downloading just the needed columns and rows. This is inefficient at best and can lead to an `Odoo Server Error: Out of memory exception` at worst.

Because of this, the current recommended way to get data is through the `search_read` function.

![Demonstration](usage.gif)

### search_read

`search_read` allows us to query an Odoo model. For more information see the [Odoo documentation](https://www.odoo.com/documentation/master/webservices/odoo.html#search-and-read). 

```M
search_read(
    model as text, 
    optional search_domain as list, 
    optional params as record, 
    optional set_schema as bool
)
```

Where:

 - `model`: Technical name of the model to query. *Examples: "res.partner", "account.invoice"*.

 - `search_domain`: An Odoo [Search Domain](https://www.odoo.com/documentation/master/reference/orm.html#reference-orm-domains). 
 
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

    **Note:** If `fields` is not specified, the default behaviour is to read all fields except those `one2many` fields which reference models the user doesn't have permission to read.

 - `set_schema`: Whether or not to set the column types according to the field definition on Odoo. Defaults to `true`.

#### Example: Get the names and emails of our contacts at Azure Interior

```M
search_read(
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


## Development

### Build
1. Install Visual Studio Code
2. Install the [Power Query SDK](https://marketplace.visualstudio.com/items?itemName=PowerQuery.vscode-powerquery-sdk) VS Code extension
3. Clone this repository and open it in VS Code
5. Compile and install (*Terminal > Run Task > Build and copy to Customs Connectors folder / Ctrl+Shift+B*)

Alternatively, you can just compress the repository to a `.zip` file and then change the extension to `.mez`.

### Test
By default the unit tests assume there's a non-empty Odoo instance running at http://localhost:8069 with a database named `db`. A `docker-compose.yml` file is provided to easily set up such an instance. Just execute `docker-compose up`, wait a bit, go to http://localhost:8069 and set up the database with sample data. If you want to use some other server for the tests, edit `test-server.json`.

Once that server is reachable, press `Set credential` in the Power Query SDK sidebar and enter your Odoo test db username and password. Then open `Odoo.query.pq` and press `Evaluate current file` (also in the PQ SDK sidebar).
