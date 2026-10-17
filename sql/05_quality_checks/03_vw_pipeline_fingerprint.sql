/* =====================================================================
   03_vw_pipeline_fingerprint.sql
   etl.vw_pipeline_fingerprint : row count + one checksum-style total per
   key output. Save the result before re-running the pipeline and compare
   afterwards: identical values = the rebuild is reproducible.
   Expected values: docs/data_catalog.md.
   ===================================================================== */
USE WWI_Analytics;
GO
CREATE OR ALTER VIEW etl.vw_pipeline_fingerprint
AS
SELECT 'gold.fact_order_line' AS object_name, COUNT(*) AS row_count, CAST(SUM(CAST(quantity AS BIGINT)) AS DECIMAL(28,4)) AS check_total FROM gold.fact_order_line
UNION ALL SELECT 'gold.fact_invoice_line', COUNT(*), CAST(SUM(revenue_excl_tax) AS DECIMAL(28,4)) FROM gold.fact_invoice_line
UNION ALL SELECT 'gold.fact_demand_daily', COUNT(*), CAST(SUM(CAST(demand_qty AS BIGINT)) AS DECIMAL(28,4)) FROM gold.fact_demand_daily
UNION ALL SELECT 'gold.fact_demand_monthly', COUNT(*), CAST(SUM(CAST(demand_units AS BIGINT)) AS DECIMAL(28,4)) FROM gold.fact_demand_monthly
UNION ALL SELECT 'gold.dim_customer', COUNT(*), CAST(COUNT(customer_name) AS DECIMAL(28,4)) FROM gold.dim_customer
UNION ALL SELECT 'gold.dim_stock_item', COUNT(*), CAST(SUM(last_cost_price) AS DECIMAL(28,4)) FROM gold.dim_stock_item
UNION ALL SELECT 'gold.sku_classification', COUNT(*), CAST(SUM(CASE WHEN abc_class = 'A' THEN 1 ELSE 0 END) AS DECIMAL(28,4)) FROM gold.sku_classification
UNION ALL SELECT 'gold.fact_forecast', COUNT(*), CAST(ROUND(SUM(forecast_units), 2) AS DECIMAL(28,4)) FROM gold.fact_forecast
UNION ALL SELECT 'gold.policy_parameters', COUNT(*), CAST(ROUND(SUM(safety_stock), 2) AS DECIMAL(28,4)) FROM gold.policy_parameters
UNION ALL SELECT 'gold.fact_policy_simulation', COUNT(*), CAST(ROUND(SUM(on_hand_end), 2) AS DECIMAL(28,4)) FROM gold.fact_policy_simulation
UNION ALL SELECT 'gold.vw_policy_kpi_scenario', COUNT(*), CAST(ROUND(SUM(fill_rate * 1e6 + avg_inventory_value), 2) AS DECIMAL(28,4)) FROM gold.vw_policy_kpi_scenario;
GO
