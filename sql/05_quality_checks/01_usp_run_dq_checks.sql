/* =====================================================================
   01_usp_run_dq_checks.sql
   etl.usp_run_dq_checks : runs all data-quality checks on silver and
   appends one row per check to etl.dq_result (failed_rows = rows that
   violate the rule; 0 = pass). Severity:
     error   -> breaks joins / KPIs, must be fixed or excluded
     warning -> business anomaly, analysis must work around it
     info    -> expected behaviour worth documenting
   ===================================================================== */
USE WWI_Analytics;
GO
IF COL_LENGTH('etl.dq_result', 'run_id') IS NULL
    ALTER TABLE etl.dq_result ADD run_id INT NULL, detail NVARCHAR(400) NULL;
GO
CREATE OR ALTER PROCEDURE etl.usp_run_dq_checks
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @run INT = (SELECT ISNULL(MAX(run_id), 0) + 1 FROM etl.dq_result);

    INSERT INTO etl.dq_result (run_id, check_name, layer, failed_rows, severity, detail)
    /* ---- referential integrity ---- */
    SELECT @run, 'order_lines without order', 'silver',
           (SELECT COUNT(*) FROM silver.order_lines ol WHERE NOT EXISTS (SELECT 1 FROM silver.orders o WHERE o.order_id = ol.order_id)),
           'error', NULL
    UNION ALL
    SELECT @run, 'invoice_lines without invoice', 'silver',
           (SELECT COUNT(*) FROM silver.invoice_lines il WHERE NOT EXISTS (SELECT 1 FROM silver.invoices i WHERE i.invoice_id = il.invoice_id)),
           'error', NULL
    UNION ALL
    SELECT @run, 'order_lines with unknown stock item', 'silver',
           (SELECT COUNT(*) FROM silver.order_lines ol WHERE NOT EXISTS (SELECT 1 FROM silver.stock_item_versions v WHERE v.stock_item_id = ol.stock_item_id AND v.is_current = 1)),
           'error', NULL
    UNION ALL
    SELECT @run, 'customers referenced by orders but missing in customers', 'silver',
           (SELECT COUNT(DISTINCT o.customer_id) FROM silver.orders o WHERE NOT EXISTS (SELECT 1 FROM silver.customers c WHERE c.customer_id = o.customer_id)),
           'error', N'Row-Level Security on WideWorldImporters.Sales.Customers hides rows from wwi_etl; fix: sql/00_setup/05_grant_customer_rls_access.sql'
    UNION ALL
    /* ---- completeness ---- */
    SELECT @run, 'invoices without delivery confirmation', 'silver',
           (SELECT SUM(dq_no_delivery_confirmation) FROM silver.invoices), 'warning',
           N'Excluded from on-time-delivery KPI'
    UNION ALL
    SELECT @run, 'purchase order lines without receipt', 'silver',
           (SELECT SUM(dq_no_receipt) FROM silver.purchase_order_lines), 'info', N'Open POs at end of data'
    UNION ALL
    /* ---- business plausibility ---- */
    SELECT @run, 'invoice lines with negative profit', 'silver',
           (SELECT SUM(dq_negative_profit) FROM silver.invoice_lines), 'info', N'Sold below cost; kept, reported in margin analysis'
    UNION ALL
    SELECT @run, 'order lines short-picked (picked < ordered)', 'silver',
           (SELECT COUNT(*) FROM silver.order_lines WHERE picked_quantity < quantity), 'info', N'Drives unit fill rate < 100%'
    UNION ALL
    SELECT @run, 'SKUs whose receipts exceed 10x their issues', 'silver',
           (SELECT COUNT(*) FROM (
               SELECT stock_item_id,
                      SUM(CASE WHEN transaction_type = 'Stock Receipt' THEN quantity ELSE 0 END) AS rec,
                      -SUM(CASE WHEN transaction_type = 'Stock Issue'  THEN quantity ELSE 0 END) AS iss
               FROM silver.stock_item_transactions GROUP BY stock_item_id) x
            WHERE rec > 10 * iss), 'warning',
           N'Simulation artefact: these SKUs hold ~99.98% of all receipts; historical stock not trusted'
    UNION ALL
    SELECT @run, 'SKUs with negative implied opening stock', 'silver',
           (SELECT COUNT(*) FROM (
               SELECT h.stock_item_id, h.quantity_on_hand - SUM(t.quantity) AS opening
               FROM silver.stock_item_holdings h
               JOIN silver.stock_item_transactions t ON t.stock_item_id = h.stock_item_id
               GROUP BY h.stock_item_id, h.quantity_on_hand) x
            WHERE opening < 0), 'warning',
           N'QuantityOnHand inconsistent with movement history'
    UNION ALL
    SELECT @run, 'SKUs whose receipts < 1% of issues', 'silver',
           (SELECT COUNT(*) FROM (
               SELECT stock_item_id,
                      SUM(CASE WHEN transaction_type = 'Stock Receipt' THEN quantity ELSE 0 END) AS rec,
                      -SUM(CASE WHEN transaction_type = 'Stock Issue'  THEN quantity ELSE 0 END) AS iss
               FROM silver.stock_item_transactions GROUP BY stock_item_id) x
            WHERE rec < 0.01 * iss), 'warning',
           N'Shipped far more than ever received: purchasing history incomplete'
    UNION ALL
    SELECT @run, 'PO lines received in < 50% of expected lead time', 'silver',
           (SELECT COUNT(*) FROM silver.purchase_order_lines
            WHERE last_receipt_date IS NOT NULL AND actual_lead_days < 0.5 * expected_lead_days), 'warning',
           N'Declared lead times ~19 d vs actual ~1.4 d; planning parameters inflated'
    UNION ALL
    SELECT @run, 'stock item versions with changed planning attributes', 'silver',
           (SELECT COUNT(*) FROM (
               SELECT unit_price, lead_time_days, quantity_per_outer,
                      LAG(unit_price)         OVER (PARTITION BY stock_item_id ORDER BY valid_from) AS p_price,
                      LAG(lead_time_days)     OVER (PARTITION BY stock_item_id ORDER BY valid_from) AS p_lt,
                      LAG(quantity_per_outer) OVER (PARTITION BY stock_item_id ORDER BY valid_from) AS p_qpo
               FROM silver.stock_item_versions) v
            WHERE p_price <> unit_price OR p_lt <> lead_time_days OR p_qpo <> quantity_per_outer), 'info',
           N'0 => temporal history holds technical edits only; dim_stock_item kept as SCD Type 1';

    SELECT check_name, severity, failed_rows, detail FROM etl.dq_result WHERE run_id = @run ORDER BY dq_id;
END
GO
