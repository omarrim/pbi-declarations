# pbi-declarations

Two small scripts that read a Power BI semantic model saved as a project (`<Name>.SemanticModel`, TMDL format) and write `declarations.json`: the **names** of its tables, columns and measures, their data types, sort columns and format strings, and which tables are related. Nothing else leaves your machine.

Made for [ChartCraft Bespoke](https://chartcraft.io/bespoke), where a report is designed and built on your model without ever seeing your data. Also what the ChartCraft MCP server's `suggest_binding` tool expects.

## What is read, what is not

| Read and written | Never read |
|---|---|
| Table names, `isHidden`, `dataCategory: Time` | Partitions, M queries, data |
| Column names, `dataType`, `sortByColumn`, `isHidden`, `dataCategory: ImageUrl` | DAX expressions (only the **first line** of a measure is looked at, to tell text from numbers; it is not written) |
| Measure names, `formatString`, `isHidden`, whether the measure returns text | Annotations, lineage tags, display folders, descriptions |
| Table pairs from `relationships.tmdl` | Row-level security, roles, cultures, perspectives |

`declarations.json` is plain text. Open it and read it before you send it.

## Run it

**Windows, nothing to install.** Right-click `Export-Declarations.ps1`, choose *Run with PowerShell*, and paste the path of your `<Name>.SemanticModel` folder (or of the project folder that contains it). Or from a terminal:

```powershell
powershell -ExecutionPolicy Bypass -File .\Export-Declarations.ps1 "C:\Reports\Sales\Sales.SemanticModel"
```

**Mac, Linux, or any machine with Node 18+:**

```bash
node export-declarations.mjs "/path/to/Sales.SemanticModel"
```

Both write `declarations.json` in the current folder (`-o other.json` / `-Out other.json` to choose) and print a summary:

```
Sales.SemanticModel: 9 tables, 61 columns, 48 measures, 8 relationships.
  DimCustomer: 7 columns, 0 measures
  DimDate: 10 columns, 0 measures, date table
  ...
  _Measures: 1 columns, 48 measures
Written: C:\Reports\Sales\declarations.json. Names only: no data, no DAX, no M. Open it, read it, then send it.
```

The two scripts produce the same file for the same model. `node check/compare.mjs a.json b.json` says whether two files hold the same declarations.

## Where is my `.SemanticModel` folder?

In Power BI Desktop: *File > Options > Preview features > Power BI Project (.pbip) save option*, then *Save as* and pick **Power BI project files (*.pbip)**. Next to the `.pbip` file you get `<Name>.Report` and `<Name>.SemanticModel`. The model must be in **TMDL** format (`definition\tables\*.tmdl`); recent versions of Desktop save it that way by default. If you see a single `model.bim` instead, enable *TMDL* in the same preview features and save again.

## What the file looks like

```json
{
  "modelFolder": "Sales.SemanticModel",
  "tables": [
    {
      "name": "DimDate",
      "isDateTable": true,
      "columns": [
        { "name": "Date", "dataType": "dateTime" },
        { "name": "Month", "dataType": "string", "sortByColumn": "MonthNumber" }
      ],
      "measures": []
    },
    {
      "name": "_Measures",
      "columns": [{ "name": "Column", "dataType": "string", "hidden": true }],
      "measures": [
        { "name": "Revenue", "formatString": "#,0" },
        { "name": "Revenue label", "isText": true }
      ]
    }
  ],
  "relationships": [{ "fromTable": "FactSales", "toTable": "DimDate" }]
}
```

## Licence

MIT. Use it, change it, ship it.
