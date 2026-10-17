/* =====================================================================
   01_usp_load_gold.sql
   gold.usp_load_gold : builds the star schema used by analysis + Power BI.
   Dimensions : dim_date, dim_stock_item (SCD1 - history has no attribute
                changes, see DQ check), bridge_stock_item_group, dim_customer,
                dim_supplier, dim_delivery_method
   Facts      : fact_order_line (demand + service), fact_invoice_line
                (shipments, revenue, delivery KPIs), fact_purchase_order_line
                (lead-time audit only), fact_demand_daily (SKU x calendar day,
                zero-filled; input of the policy simulation)
   Keys: unique clustered indexes (not PK constraints) - SELECT INTO can produce
         nullable columns, and a PK on them fails inside the procedure.
   Notes from profiling:
     - A backorder "child" order holds the lines that could not be supplied
       on the parent order (same day, different lines) -> no double counting,
       total demand = all order lines.
     - 3,147 order lines were never picked (picked_quantity = 0) -> lost/unshipped demand.
     - No orders on Sundays; Saturday volume ~half of a weekday.
   ===================================================================== */
USE WWI_Analytics;
GO
CREATE OR ALTER PROCEDURE gold.usp_load_gold
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t DATETIME2(0), @n INT, @first_log INT = (SELECT ISNULL(MAX(log_id),0)+1 FROM etl.load_log);
    DECLARE @calib_end DATE = '2015-05-31', @data_end DATE = '2016-05-31';

    BEGIN TRY
    /* ---------- dim_date ---------- */
    SET @t = SYSDATETIME();
    DROP TABLE IF EXISTS gold.dim_date;
    WITH n AS (SELECT TOP (DATEDIFF(DAY, '2013-01-01', '2016-12-31') + 1)
                      ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS i
               FROM sys.all_objects a CROSS JOIN sys.all_objects b)
    SELECT  ISNULL(CAST(CONVERT(CHAR(8), d, 112) AS INT), 0) AS date_key,   -- ISNULL => NOT NULL column (needed for PK)
            d                                           AS [date],
            YEAR(d)                                     AS [year],
            DATEPART(QUARTER, d)                        AS [quarter],
            MONTH(d)                                    AS [month],
            DATENAME(MONTH, d)                          AS month_name,
            DATEFROMPARTS(YEAR(d), MONTH(d), 1)         AS month_start,
            DATEPART(ISO_WEEK, d)                       AS iso_week,
            DATEADD(DAY, -((DATEPART(WEEKDAY, d) + @@DATEFIRST - 2) % 7), d) AS week_start_monday,
            (DATEPART(WEEKDAY, d) + @@DATEFIRST - 2) % 7 + 1 AS weekday_no,   -- 1 = Monday
            DATENAME(WEEKDAY, d)                        AS weekday_name,
            CASE WHEN (DATEPART(WEEKDAY, d) + @@DATEFIRST - 2) % 7 + 1 = 7 THEN 0 ELSE 1 END AS is_trading_day,
            CASE WHEN d <= @calib_end THEN 'calibration'
                 WHEN d <= @data_end  THEN 'test'
                 ELSE 'future' END                      AS model_period
    INTO gold.dim_date
    FROM (SELECT DATEADD(DAY, i, CAST('2013-01-01' AS DATE)) AS d FROM n) x;
    SET @n = @@ROWCOUNT; CREATE UNIQUE CLUSTERED INDEX UX_dim_date ON gold.dim_date (date_key);
    EXEC silver.usp_log 'gold.dim_date', @n, @t;

    /* ---------- dim_stock_item ---------- */
    SET @t = SYSDATETIME();
    DROP TABLE IF EXISTS gold.dim_stock_item;
    SELECT  v.stock_item_id,
            v.stock_item_name,
            v.brand, v.size,
            c.ColorName                     AS color,
            up.PackageTypeName              AS unit_package,
            op.PackageTypeName              AS outer_package,
            v.quantity_per_outer,
            v.lead_time_days                AS declared_lead_time_days,
            v.is_chiller_stock,
            v.unit_price,
            v.recommended_retail_price,
            h.last_cost_price,
            h.reorder_level                 AS erp_reorder_level,
            h.target_stock_level            AS erp_target_stock_level,
            h.quantity_on_hand              AS erp_quantity_on_hand,
            s.supplier_name,
            g.primary_stock_group,
            g.stock_groups
    INTO gold.dim_stock_item
    FROM silver.stock_item_versions v
    LEFT JOIN silver.stock_item_holdings h  ON h.stock_item_id = v.stock_item_id
    LEFT JOIN silver.suppliers s            ON s.supplier_id = v.supplier_id
    LEFT JOIN bronze.warehouse_colors c     ON c.ColorID = v.color_id
    LEFT JOIN bronze.warehouse_package_types up ON up.PackageTypeID = v.unit_package_id
    LEFT JOIN bronze.warehouse_package_types op ON op.PackageTypeID = v.outer_package_id
    OUTER APPLY (SELECT MIN(stock_group_name) AS primary_stock_group,
                        STRING_AGG(stock_group_name, ', ') WITHIN GROUP (ORDER BY stock_group_name) AS stock_groups
                 FROM silver.stock_item_groups sg WHERE sg.stock_item_id = v.stock_item_id) g
    WHERE v.is_current = 1;
    SET @n = @@ROWCOUNT; CREATE UNIQUE CLUSTERED INDEX UX_dim_stock_item ON gold.dim_stock_item (stock_item_id);
    EXEC silver.usp_log 'gold.dim_stock_item', @n, @t;

    SET @t = SYSDATETIME();
    DROP TABLE IF EXISTS gold.bridge_stock_item_group;
    SELECT stock_item_id, stock_group_id, stock_group_name INTO gold.bridge_stock_item_group FROM silver.stock_item_groups;
    SET @n = @@ROWCOUNT;
    EXEC silver.usp_log 'gold.bridge_stock_item_group', @n, @t;

    /* ---------- dim_customer (all customers seen in orders; attributes when visible) ---------- */
    SET @t = SYSDATETIME();
    DROP TABLE IF EXISTS gold.dim_customer;
    SELECT  ids.customer_id,
            ISNULL(c.customer_name, CONCAT('Customer ', ids.customer_id)) AS customer_name,
            ISNULL(c.customer_category, 'Unknown') AS customer_category,
            ISNULL(c.buying_group, 'None / unknown') AS buying_group,
            ci.city_name, ci.state_name, ci.sales_territory,
            CASE WHEN c.customer_id IS NULL THEN 0 ELSE 1 END AS has_attributes
    INTO gold.dim_customer
    FROM (SELECT DISTINCT customer_id FROM silver.orders) ids
    LEFT JOIN silver.customers c ON c.customer_id = ids.customer_id
    LEFT JOIN silver.cities ci   ON ci.city_id = c.delivery_city_id;
    SET @n = @@ROWCOUNT; CREATE UNIQUE CLUSTERED INDEX UX_dim_customer ON gold.dim_customer (customer_id);
    EXEC silver.usp_log 'gold.dim_customer', @n, @t;

    SET @t = SYSDATETIME();
    DROP TABLE IF EXISTS gold.dim_supplier;
    SELECT supplier_id, supplier_name, supplier_category, payment_days INTO gold.dim_supplier FROM silver.suppliers;
    SET @n = @@ROWCOUNT;
    EXEC silver.usp_log 'gold.dim_supplier', @n, @t;

    SET @t = SYSDATETIME();
    DROP TABLE IF EXISTS gold.dim_delivery_method;
    SELECT delivery_method_id, delivery_method_name INTO gold.dim_delivery_method FROM silver.delivery_methods;
    SET @n = @@ROWCOUNT;
    EXEC silver.usp_log 'gold.dim_delivery_method', @n, @t;

    /* ---------- fact_order_line ---------- */
    SET @t = SYSDATETIME();
    DROP TABLE IF EXISTS gold.fact_order_line;
    SELECT  ol.order_line_id, ol.order_id,
            CAST(CONVERT(CHAR(8), o.order_date, 112) AS INT) AS order_date_key,
            o.order_date, o.expected_delivery_date,
            o.customer_id, ol.stock_item_id,
            ol.quantity, ol.picked_quantity,
            ol.quantity - ol.picked_quantity                       AS unshipped_quantity,
            ol.unit_price, ol.line_value_excl_tax,
            CASE WHEN par.order_id IS NOT NULL THEN 1 ELSE 0 END    AS is_backorder_line,      -- line sits on a backorder (child) order
            CASE WHEN o.backorder_order_id IS NOT NULL THEN 1 ELSE 0 END AS order_was_split,    -- parent order spawned a backorder
            CASE WHEN ol.picked_quantity = 0 AND ol.picking_completed_at IS NULL THEN 1 ELSE 0 END AS is_never_picked
    INTO gold.fact_order_line
    FROM silver.order_lines ol
    JOIN silver.orders o ON o.order_id = ol.order_id
    LEFT JOIN (SELECT DISTINCT backorder_order_id AS order_id FROM silver.orders WHERE backorder_order_id IS NOT NULL) par
           ON par.order_id = o.order_id;
    SET @n = @@ROWCOUNT; CREATE UNIQUE CLUSTERED INDEX UX_fact_order_line ON gold.fact_order_line (order_line_id);
    EXEC silver.usp_log 'gold.fact_order_line', @n, @t;

    /* ---------- fact_invoice_line ---------- */
    SET @t = SYSDATETIME();
    DROP TABLE IF EXISTS gold.fact_invoice_line;
    SELECT  il.invoice_line_id, il.invoice_id, i.order_id,
            CAST(CONVERT(CHAR(8), i.invoice_date, 112) AS INT) AS invoice_date_key,
            i.invoice_date, o.order_date, o.expected_delivery_date, i.confirmed_delivery_date,
            i.customer_id, il.stock_item_id, i.delivery_method_id,
            il.quantity, il.unit_price, il.revenue_excl_tax, il.tax_amount, il.line_profit,
            DATEDIFF(DAY, o.order_date, i.confirmed_delivery_date) AS days_order_to_delivery,
            CASE WHEN i.confirmed_delivery_date IS NULL THEN NULL
                 WHEN i.confirmed_delivery_date <= o.expected_delivery_date THEN 1 ELSE 0 END AS is_on_time
    INTO gold.fact_invoice_line
    FROM silver.invoice_lines il
    JOIN silver.invoices i ON i.invoice_id = il.invoice_id
    JOIN silver.orders o   ON o.order_id = i.order_id;
    SET @n = @@ROWCOUNT; CREATE UNIQUE CLUSTERED INDEX UX_fact_invoice_line ON gold.fact_invoice_line (invoice_line_id);
    EXEC silver.usp_log 'gold.fact_invoice_line', @n, @t;

    /* ---------- fact_purchase_order_line (lead-time audit) ---------- */
    SET @t = SYSDATETIME();
    DROP TABLE IF EXISTS gold.fact_purchase_order_line;
    SELECT  p.purchase_order_line_id, p.purchase_order_id, p.supplier_id, p.stock_item_id,
            p.order_date, p.expected_delivery_date, p.last_receipt_date,
            p.ordered_outers, p.received_outers, p.expected_unit_price_per_outer,
            p.actual_lead_days, p.expected_lead_days, d.declared_lead_time_days
    INTO gold.fact_purchase_order_line
    FROM silver.purchase_order_lines p
    LEFT JOIN gold.dim_stock_item d ON d.stock_item_id = p.stock_item_id;
    SET @n = @@ROWCOUNT;
    EXEC silver.usp_log 'gold.fact_purchase_order_line', @n, @t;

    /* ---------- fact_demand_daily : SKU x calendar day, zero-filled ---------- */
    SET @t = SYSDATETIME();
    DROP TABLE IF EXISTS gold.fact_demand_daily;
    SELECT  s.stock_item_id, d.date_key, d.[date],
            ISNULL(x.demand_qty, 0)  AS demand_qty,
            ISNULL(x.order_lines, 0) AS order_lines
    INTO gold.fact_demand_daily
    FROM gold.dim_stock_item s
    CROSS JOIN gold.dim_date d
    LEFT JOIN (SELECT stock_item_id, order_date, SUM(quantity) AS demand_qty, COUNT(*) AS order_lines
               FROM gold.fact_order_line GROUP BY stock_item_id, order_date) x
           ON x.stock_item_id = s.stock_item_id AND x.order_date = d.[date]
    WHERE d.[date] <= @data_end;
    SET @n = @@ROWCOUNT; CREATE UNIQUE CLUSTERED INDEX UX_fact_demand_daily ON gold.fact_demand_daily (stock_item_id, date_key);
    EXEC silver.usp_log 'gold.fact_demand_daily', @n, @t;
    END TRY
    BEGIN CATCH
        INSERT INTO etl.load_log (layer, object_name, load_type, finished_at, status, error_message)
        VALUES ('gold', 'usp_load_gold', 'full', SYSDATETIME(), 'failed', ERROR_MESSAGE());
    END CATCH

    SELECT log_id, object_name, rows_affected, status, error_message
    FROM etl.load_log WHERE log_id >= @first_log ORDER BY log_id;
END
GO
