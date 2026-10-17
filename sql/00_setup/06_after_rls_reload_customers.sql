/* =====================================================================
   06_after_rls_reload_customers.sql
   Run AFTER 05_grant_customer_rls_access.sql (can be run as wwi_etl or admin).
   Reloads customers end-to-end so dim_customer gets names, categories,
   buying groups and geography; re-runs the DQ checks (the 663-customer
   error should drop to 0). Simulation does not depend on customers.
   ===================================================================== */
USE WWI_Analytics;
GO
EXEC bronze.usp_load_bronze @load_type = 'full', @only_table = 'sales_customers';
EXEC silver.usp_load_silver;
EXEC gold.usp_load_gold;
EXEC etl.usp_run_dq_checks;
SELECT has_attributes, COUNT(*) AS customers FROM gold.dim_customer GROUP BY has_attributes;
GO
