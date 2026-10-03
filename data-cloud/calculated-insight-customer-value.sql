-- Calculated Insight: Customer_Value__cio
-- One row per Unified Individual (after identity resolution) with lifetime value metrics.
-- Notes:
--   * Only confirmed ('Activated') orders count: spend, order count AND last order date.
--     The filter is a WHERE clause because the CI editor only allows SUM/COUNT around CASE
--     (MAX(CASE ...) and APPROX_COUNT_DISTINCT(CASE ...) are rejected).
--   * Side effect: customers with only draft orders get no row -> Apex falls back to CRM and
--     reports dataSource = 'Salesforce CRM (no confirmed purchases in Data Cloud)'.
--   * COUNT(DISTINCT ...) is not supported in Calculated Insights -> APPROX_COUNT_DISTINCT
--   * Refresh schedule: every 24h (06:00 Europe/Zurich)
SELECT
    UnifiedIndividual__dlm.ssot__Id__c AS customer_id__c,
    SUM(ssot__SalesOrderProduct__dlm.ssot__TotalLineAmount__c) AS lifetime_spend__c,
    SUM(CASE WHEN ssot__GoodsProduct__dlm.ssot__PrimaryProductCategory__c = 'Bikes'
             THEN ssot__SalesOrderProduct__dlm.ssot__TotalLineAmount__c ELSE 0 END) AS bike_spend__c,
    SUM(CASE WHEN ssot__GoodsProduct__dlm.ssot__PrimaryProductCategory__c = 'Gear'
             THEN ssot__SalesOrderProduct__dlm.ssot__TotalLineAmount__c ELSE 0 END) AS gear_spend__c,
    APPROX_COUNT_DISTINCT(ssot__SalesOrder__dlm.ssot__Id__c) AS order_count__c,
    MAX(ssot__SalesOrder__dlm.ssot__OrderStartDate__c) AS last_order_date__c
FROM ssot__SalesOrder__dlm
JOIN IndividualIdentityLink__dlm
  ON ssot__SalesOrder__dlm.ssot__SoldToCustomerId__c = IndividualIdentityLink__dlm.SourceRecordId__c
JOIN UnifiedIndividual__dlm
  ON IndividualIdentityLink__dlm.UnifiedRecordId__c = UnifiedIndividual__dlm.ssot__Id__c
JOIN ssot__SalesOrderProduct__dlm
  ON ssot__SalesOrderProduct__dlm.ssot__SalesOrderId__c = ssot__SalesOrder__dlm.ssot__Id__c
LEFT JOIN ssot__GoodsProduct__dlm
  ON ssot__SalesOrderProduct__dlm.ssot__ProductId__c = ssot__GoodsProduct__dlm.ssot__Id__c
WHERE ssot__SalesOrder__dlm.ssot__SalesOrderStatusId__c = 'Activated'
GROUP BY UnifiedIndividual__dlm.ssot__Id__c
