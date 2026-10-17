/* =====================================================================
   06_vw_service_and_audit.sql
   gold.vw_customer_service_monthly : OTD, unit fill rate, order-split (backorder) rate   (Q5)
   gold.vw_backorder_by_sku         : which SKUs drive backorders / unshipped demand     (Q5)
   gold.vw_lead_time_audit          : declared vs actual supplier lead time and what the
                                      inflated parameter costs in average inventory      (Q4)
   ===================================================================== */
USE WWI_Analytics;
GO
CREATE OR ALTER VIEW gold.vw_customer_service_monthly
AS
WITH o AS (
    SELECT DATEFROMPARTS(YEAR(order_date), MONTH(order_date), 1) AS month_start,
           COUNT(DISTINCT order_id)                                   AS orders,
           COUNT(DISTINCT CASE WHEN is_backorder_line = 0 THEN order_id END) AS original_orders,
           COUNT(DISTINCT CASE WHEN order_was_split = 1 AND is_backorder_line = 0 THEN order_id END) AS split_orders,
           COUNT(*)                                                   AS order_lines,
           SUM(quantity)                                              AS units_ordered,
           SUM(picked_quantity)                                       AS units_picked,
           SUM(is_never_picked)                                       AS lines_never_picked,
           SUM(CASE WHEN is_backorder_line = 1 THEN quantity ELSE 0 END) AS units_on_backorder
    FROM gold.fact_order_line
    GROUP BY DATEFROMPARTS(YEAR(order_date), MONTH(order_date), 1)),
d AS (
    SELECT DATEFROMPARTS(YEAR(invoice_date), MONTH(invoice_date), 1) AS month_start,
           COUNT(DISTINCT invoice_id) AS invoices,
           COUNT(DISTINCT CASE WHEN is_on_time = 1 THEN invoice_id END) AS invoices_on_time,
           COUNT(DISTINCT CASE WHEN is_on_time IS NOT NULL THEN invoice_id END) AS invoices_delivered,
           AVG(CAST(days_order_to_delivery AS FLOAT)) AS avg_days_order_to_delivery
    FROM gold.fact_invoice_line
    GROUP BY DATEFROMPARTS(YEAR(invoice_date), MONTH(invoice_date), 1))
SELECT o.month_start, o.orders, o.original_orders, o.split_orders,
       CAST(o.split_orders AS FLOAT) / NULLIF(o.original_orders, 0) AS order_split_rate,
       o.order_lines, o.units_ordered, o.units_picked,
       CAST(o.units_picked AS FLOAT) / NULLIF(o.units_ordered, 0)   AS unit_fill_rate,
       o.lines_never_picked, o.units_on_backorder,
       d.invoices, d.invoices_delivered, d.invoices_on_time,
       CAST(d.invoices_on_time AS FLOAT) / NULLIF(d.invoices_delivered, 0) AS on_time_delivery_rate,
       d.avg_days_order_to_delivery
FROM o LEFT JOIN d ON d.month_start = o.month_start;
GO
CREATE OR ALTER VIEW gold.vw_backorder_by_sku
AS
SELECT  f.stock_item_id, i.stock_item_name, i.primary_stock_group, c.abc_class,
        SUM(f.quantity)                                                   AS units_ordered,
        SUM(CASE WHEN f.is_backorder_line = 1 THEN f.quantity ELSE 0 END) AS units_on_backorder,
        SUM(CASE WHEN f.is_backorder_line = 1 THEN 1 ELSE 0 END)          AS backorder_lines,
        SUM(f.unshipped_quantity)                                         AS units_never_shipped,
        CAST(SUM(CASE WHEN f.is_backorder_line = 1 THEN f.quantity ELSE 0 END) AS FLOAT)
            / NULLIF(SUM(f.quantity), 0)                                  AS backorder_unit_share,
        RANK() OVER (ORDER BY SUM(CASE WHEN f.is_backorder_line = 1 THEN f.quantity ELSE 0 END) DESC) AS backorder_rank
FROM gold.fact_order_line f
JOIN gold.dim_stock_item i ON i.stock_item_id = f.stock_item_id
LEFT JOIN gold.sku_classification c ON c.stock_item_id = f.stock_item_id
GROUP BY f.stock_item_id, i.stock_item_name, i.primary_stock_group, c.abc_class;
GO
CREATE OR ALTER VIEW gold.vw_lead_time_audit
AS
WITH po AS (
    SELECT stock_item_id, COUNT(*) AS po_lines,
           AVG(CAST(actual_lead_days AS FLOAT))   AS avg_actual_lead_days,
           MAX(actual_lead_days)                  AS max_actual_lead_days,
           AVG(CAST(expected_lead_days AS FLOAT)) AS avg_po_expected_lead_days
    FROM gold.fact_purchase_order_line
    WHERE actual_lead_days IS NOT NULL
    GROUP BY stock_item_id),
inv AS (
    SELECT stock_item_id,
           MAX(CASE WHEN scenario_id = 2  THEN avg_on_hand_value END) AS inv_value_declared_95,
           MAX(CASE WHEN scenario_id = 10 THEN avg_on_hand_value END) AS inv_value_actual3d_95,
           MAX(CASE WHEN scenario_id = 2  THEN fill_rate END)         AS fill_declared_95,
           MAX(CASE WHEN scenario_id = 10 THEN fill_rate END)         AS fill_actual3d_95
    FROM gold.vw_policy_kpi_sku WHERE run_type = 'replay'
    GROUP BY stock_item_id)
SELECT  i.stock_item_id, i.stock_item_name, i.supplier_name, i.declared_lead_time_days,
        po.po_lines, po.avg_actual_lead_days, po.max_actual_lead_days, po.avg_po_expected_lead_days,
        i.declared_lead_time_days - ISNULL(po.avg_actual_lead_days, 3) AS lead_time_overstatement_days,
        inv.inv_value_declared_95, inv.inv_value_actual3d_95,
        inv.inv_value_declared_95 - inv.inv_value_actual3d_95 AS excess_inventory_value,
        inv.fill_declared_95, inv.fill_actual3d_95
FROM gold.dim_stock_item i
LEFT JOIN po  ON po.stock_item_id  = i.stock_item_id
LEFT JOIN inv ON inv.stock_item_id = i.stock_item_id;
GO
