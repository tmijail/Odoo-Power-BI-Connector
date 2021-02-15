# Odoo - Power BI Connector

This project allows Power BI to query data from Odoo through the JsonRPC API. 

Before this connector, the only way to query Odoo from Power BI was to connect directly to the PostreSQL database. This is impossible if, for example, the Odoo instance is hosted on odoo.sh or on some other platform which doesn't expose the database to the internet.

## Build
1. Install Visual Studio
2. Install the [Power Query SDK](https://marketplace.visualstudio.com/items?itemName=Dakahn.PowerQuerySDK)
3. Clone this repository and open `Odoo.sln`
4. *Optional:* Install and configure the [Auto Deploy](https://marketplace.visualstudio.com/items?itemName=lennyomg.AutoDeploy) extension to copy `Odoo.mez` to `%USERPROFILE%\Documents\Power BI Desktop\Custom Connectors` after every build.
5. Compile (*Build > Build Solution / Ctrl+Shift+B*)

## Install
1. Create a `%USERPROFILE%\Documents\Power BI Desktop\Custom Connectors` directory.
2. Copy `Odoo.mez` into that directory.
3. Open Power BI Desktop and enable loading unsigned connectors (*File > Options and settings > Options > Security > Data Extensions > Allow any extension to load without warning or validation*)
4. Restart Power BI Desktop