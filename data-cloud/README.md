# Data Cloud setup

Configured in a Developer Edition org. Documented here so it can be reproduced.

## 1. Data streams (Salesforce CRM connector)

| Source object | Mapped to DMO |
|---|---|
| Contact | Individual, Contact Point Email |
| Order | Sales Order (EffectiveDate → Order Start Date; event time = CreatedDate, since EffectiveDate is a Date, not DateTime) |
| OrderItem | Sales Order Product |
| Product2 | Goods Product (Family → Primary Product Category; StockKeepingUnit populated first) |

Appointments are read by Apex straight from `Store_Appointment__c`, so they don't need a stream.

## 2. Identity resolution

Match rule: exact normalized email. Output: `UnifiedIndividual__dlm` + `IndividualIdentityLink__dlm`
(the link table maps a CRM Contact Id to its Unified Individual).

## 3. Calculated Insight

`Customer_Value__cio` – see [`calculated-insight-customer-value.sql`](calculated-insight-customer-value.sql).
Only confirmed (`Activated`) orders are counted. Refreshed every 24h (06:00 Europe/Zurich).

It can be created in the UI, or with the Connect REST API:

```bash
# ci.json: {"apiName": "Customer_Value", "displayName": "Customer Value", "definitionType": "CALCULATED_METRIC",
#           "expression": "<the SQL>", "publishScheduleInterval": "TwentyFour",
#           "publishScheduleStartDateTime": "2026-10-04T06:00"}
sf api request rest /services/data/v66.0/ssot/calculated-insights --method POST --body @ci.json -o <org>
```

## 4. Consumed from Apex

`CustomerProfileService` queries the insight via `ConnectApi.CdpQuery.queryAnsiSqlV2`, joining
through `IndividualIdentityLink__dlm` on the Contact Id, and falls back to CRM figures when there is
no row or Data Cloud is unavailable. The output field `dataSource` reports which path was used.

## Refreshing after new demo data

New CRM records reach the insight in three steps: the CRM streams pick them up (incremental),
identity resolution links them to a Unified Individual, then the insight is recalculated.
To speed this up for a demo:

```bash
# identity resolution ruleset id: GET /services/data/v66.0/ssot/identity-resolutions
sf api request rest /services/data/v66.0/ssot/identity-resolutions/<id>/actions/run-now --method POST --body @empty.json -o <org>
```

Until then the agents keep working: the profile reports
`Salesforce CRM (no confirmed purchases in Data Cloud)` and uses the CRM figures.

## Gotchas hit along the way

- Developer Edition cannot switch a DMO mapping once saved – plan mappings before saving.
- Event-time fields must be DateTime.
- `COUNT(DISTINCT)` → `APPROX_COUNT_DISTINCT` in Calculated Insights, and the CI editor only allows
  `SUM`/`COUNT` around `CASE`, so "confirmed orders only" has to be a `WHERE` clause.
- Calculated Insight API names get the `__cio` suffix; check the exact name before querying.
- The CI REST API wants `publishScheduleInterval: "TwentyFour"` (not the `TWENTY_FOUR` it returns
  on GET) plus a `publishScheduleStartDateTime`.
- `sf api request rest` needs a body file for POST actions, even an empty `{}`.
