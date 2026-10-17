/* =====================================================================
   01_usp_load_silver.sql
   silver.usp_load_silver : rebuilds every silver table from bronze.
   Silver = typed, trimmed, only analysis columns, + data-quality flags.
   Fully reproducible from bronze, so each table is dropped and rebuilt.
   DQ flags (dq_*) mark suspicious rows instead of deleting them; the
   checks in sql/05_quality_checks summarise them into etl.dq_result.
   ===================================================================== */
USE WWI_Analytics;
GO
CREATE OR ALTER PROCEDURE silver.usp_log
    @object SYSNAME, @rows INT, @started DATETIME2(0)
AS
    INSERT INTO etl.load_log (layer, object_name, load_type, rows_affected, started_at, finished_at, status)
    VALUES (CASE WHEN @object LIKE 'gold.%' THEN 'gold' ELSE 'silver' END,  -- gold loader reuses this logger
            @object, 'full', @rows, @started, SYSDATETIME(), 'success');
GO
CREATE OR ALTER PROCEDURE silver.usp_load_silver
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t DATETIME2(0), @n INT, @first_log INT = (SELECT ISNULL(MAX(log_id),0)+1 FROM etl.load_log);

    BEGIN TRY
    /* ---------- Sales: orders ---------- */
    SET @t = SYSDATETIME();
    DROP TABLE IF EXISTS silver.orders;
    SELECT  o.OrderID                         AS order_id,
            o.CustomerID                      AS customer_id,
            o.SalespersonPersonID             AS salesperson_id,
            CAST(o.OrderDate AS DATE)         AS order_date,
            CAST(o.ExpectedDeliveryDate AS DATE) AS expected_delivery_date,
            o.BackorderOrderID                AS backorder_order_id,
            CAST(o.IsUndersupplyBackordered AS BIT) AS is_undersupply_backordered,
            o.PickingCompletedWhen            AS picking_completed_at,
            CASE WHEN o.ExpectedDeliveryDate < o.OrderDate THEN 1 ELSE 0 END AS dq_expected_before_order
    INTO silver.orders
    FROM bronze.sales_orders o;
    SET @n = @@ROWCOUNT; ALTER TABLE silver.orders ADD CONSTRAINT PK_silver_orders PRIMARY KEY (order_id);
    EXEC silver.usp_log 'orders', @n, @t;

    /* ---------- Sales: order lines (= demand) ---------- */
    SET @t = SYSDATETIME();
    DROP TABLE IF EXISTS silver.order_lines;
    SELECT  ol.OrderLineID     AS order_line_id,
            ol.OrderID         AS order_id,
            ol.StockItemID     AS stock_item_id,
            ol.Quantity        AS quantity,
            ol.PickedQuantity  AS picked_quantity,
            CAST(ol.UnitPrice AS DECIMAL(18,2)) AS unit_price,
            CAST(ol.TaxRate   AS DECIMAL(18,3)) AS tax_rate,
            CAST(ol.Quantity * ol.UnitPrice AS DECIMAL(18,2)) AS line_value_excl_tax,
            ol.PickingCompletedWhen AS picking_completed_at,
            CASE WHEN ol.Quantity <= 0 THEN 1 ELSE 0 END                 AS dq_non_positive_qty,
            CASE WHEN ol.PickedQuantity > ol.Quantity THEN 1 ELSE 0 END   AS dq_over_picked
    INTO silver.order_lines
    FROM bronze.sales_order_lines ol;
    SET @n = @@ROWCOUNT; ALTER TABLE silver.order_lines ADD CONSTRAINT PK_silver_order_lines PRIMARY KEY (order_line_id);
    EXEC silver.usp_log 'order_lines', @n, @t;

    /* ---------- Sales: invoices (= shipments) ---------- */
    SET @t = SYSDATETIME();
    DROP TABLE IF EXISTS silver.invoices;
    SELECT  i.InvoiceID           AS invoice_id,
            i.OrderID             AS order_id,
            i.CustomerID          AS customer_id,
            i.BillToCustomerID    AS bill_to_customer_id,
            i.DeliveryMethodID    AS delivery_method_id,
            CAST(i.InvoiceDate AS DATE)            AS invoice_date,
            i.ConfirmedDeliveryTime                AS confirmed_delivery_at,
            CAST(i.ConfirmedDeliveryTime AS DATE)  AS confirmed_delivery_date,
            CAST(i.IsCreditNote AS BIT)            AS is_credit_note,
            i.TotalDryItems       AS total_dry_items,
            i.TotalChillerItems   AS total_chiller_items,
            CASE WHEN i.ConfirmedDeliveryTime IS NULL THEN 1 ELSE 0 END                         AS dq_no_delivery_confirmation,
            CASE WHEN CAST(i.ConfirmedDeliveryTime AS DATE) < CAST(i.InvoiceDate AS DATE) THEN 1 ELSE 0 END AS dq_delivered_before_invoice
    INTO silver.invoices
    FROM bronze.sales_invoices i;
    SET @n = @@ROWCOUNT; ALTER TABLE silver.invoices ADD CONSTRAINT PK_silver_invoices PRIMARY KEY (invoice_id);
    EXEC silver.usp_log 'invoices', @n, @t;

    SET @t = SYSDATETIME();
    DROP TABLE IF EXISTS silver.invoice_lines;
    SELECT  il.InvoiceLineID  AS invoice_line_id,
            il.InvoiceID      AS invoice_id,
            il.StockItemID    AS stock_item_id,
            il.Quantity       AS quantity,
            CAST(il.UnitPrice     AS DECIMAL(18,2)) AS unit_price,
            CAST(il.TaxAmount     AS DECIMAL(18,2)) AS tax_amount,
            CAST(il.ExtendedPrice AS DECIMAL(18,2)) AS extended_price_incl_tax,
            CAST(il.ExtendedPrice - il.TaxAmount AS DECIMAL(18,2)) AS revenue_excl_tax,
            CAST(il.LineProfit    AS DECIMAL(18,2)) AS line_profit,
            CASE WHEN il.LineProfit < 0 THEN 1 ELSE 0 END AS dq_negative_profit
    INTO silver.invoice_lines
    FROM bronze.sales_invoice_lines il;
    SET @n = @@ROWCOUNT; ALTER TABLE silver.invoice_lines ADD CONSTRAINT PK_silver_invoice_lines PRIMARY KEY (invoice_line_id);
    EXEC silver.usp_log 'invoice_lines', @n, @t;

    /* ---------- Customers (needs RLS grant, see 00_setup/05) ---------- */
    SET @t = SYSDATETIME();
    DROP TABLE IF EXISTS silver.customers;
    SELECT  c.CustomerID          AS customer_id,
            LTRIM(RTRIM(c.CustomerName)) AS customer_name,
            c.BillToCustomerID    AS bill_to_customer_id,
            cc.CustomerCategoryName AS customer_category,
            bg.BuyingGroupName    AS buying_group,
            c.DeliveryCityID      AS delivery_city_id,
            CAST(c.AccountOpenedDate AS DATE) AS account_opened_date,
            CAST(c.CreditLimit AS DECIMAL(18,2)) AS credit_limit,
            c.PaymentDays         AS payment_days
    INTO silver.customers
    FROM bronze.sales_customers c
    LEFT JOIN bronze.sales_customer_categories cc ON cc.CustomerCategoryID = c.CustomerCategoryID
    LEFT JOIN bronze.sales_buying_groups bg       ON bg.BuyingGroupID      = c.BuyingGroupID;
    SET @n = @@ROWCOUNT;
    EXEC silver.usp_log 'customers', @n, @t;

    /* ---------- Geography ---------- */
    SET @t = SYSDATETIME();
    DROP TABLE IF EXISTS silver.cities;
    SELECT  ci.CityID AS city_id, ci.CityName AS city_name,
            sp.StateProvinceCode AS state_code, sp.StateProvinceName AS state_name,
            sp.SalesTerritory AS sales_territory,
            co.CountryName AS country_name, co.Continent AS continent, co.Region AS region
    INTO silver.cities
    FROM bronze.application_cities ci
    JOIN bronze.application_state_provinces sp ON sp.StateProvinceID = ci.StateProvinceID
    JOIN bronze.application_countries co       ON co.CountryID       = sp.CountryID;
    SET @n = @@ROWCOUNT;
    EXEC silver.usp_log 'cities', @n, @t;

    /* ---------- Stock items: current + full history (for SCD2) ---------- */
    SET @t = SYSDATETIME();
    DROP TABLE IF EXISTS silver.stock_item_versions;
    SELECT  v.StockItemID AS stock_item_id,
            LTRIM(RTRIM(v.StockItemName)) AS stock_item_name,
            v.SupplierID AS supplier_id, v.ColorID AS color_id,
            v.UnitPackageID AS unit_package_id, v.OuterPackageID AS outer_package_id,
            NULLIF(LTRIM(RTRIM(v.Brand)), '') AS brand, NULLIF(LTRIM(RTRIM(v.Size)), '') AS size,
            v.LeadTimeDays AS lead_time_days, v.QuantityPerOuter AS quantity_per_outer,
            CAST(v.IsChillerStock AS BIT) AS is_chiller_stock,
            CAST(v.UnitPrice AS DECIMAL(18,2)) AS unit_price,
            CAST(v.RecommendedRetailPrice AS DECIMAL(18,2)) AS recommended_retail_price,
            CAST(v.TypicalWeightPerUnit AS DECIMAL(18,3)) AS typical_weight_per_unit,
            v.ValidFrom AS valid_from, v.ValidTo AS valid_to,
            v.is_current
    INTO silver.stock_item_versions
    FROM (
        SELECT StockItemID, StockItemName, SupplierID, ColorID, UnitPackageID, OuterPackageID, Brand, Size,
               LeadTimeDays, QuantityPerOuter, IsChillerStock, UnitPrice, RecommendedRetailPrice,
               TypicalWeightPerUnit, ValidFrom, ValidTo, CAST(1 AS BIT) AS is_current
        FROM bronze.warehouse_stock_items
        UNION ALL
        SELECT StockItemID, StockItemName, SupplierID, ColorID, UnitPackageID, OuterPackageID, Brand, Size,
               LeadTimeDays, QuantityPerOuter, IsChillerStock, UnitPrice, RecommendedRetailPrice,
               TypicalWeightPerUnit, ValidFrom, ValidTo, CAST(0 AS BIT)
        FROM bronze.warehouse_stock_items_archive
    ) v;
    SET @n = @@ROWCOUNT;
    EXEC silver.usp_log 'stock_item_versions', @n, @t;

    SET @t = SYSDATETIME();
    DROP TABLE IF EXISTS silver.stock_item_holdings;
    SELECT  h.StockItemID AS stock_item_id, h.QuantityOnHand AS quantity_on_hand,
            h.LastStocktakeQuantity AS last_stocktake_quantity,
            CAST(h.LastCostPrice AS DECIMAL(18,2)) AS last_cost_price,
            h.ReorderLevel AS reorder_level, h.TargetStockLevel AS target_stock_level
    INTO silver.stock_item_holdings
    FROM bronze.warehouse_stock_item_holdings h;
    SET @n = @@ROWCOUNT;
    EXEC silver.usp_log 'stock_item_holdings', @n, @t;

    SET @t = SYSDATETIME();
    DROP TABLE IF EXISTS silver.stock_item_groups;
    SELECT  sg.StockItemID AS stock_item_id, g.StockGroupID AS stock_group_id, g.StockGroupName AS stock_group_name
    INTO silver.stock_item_groups
    FROM bronze.warehouse_stock_item_stock_groups sg
    JOIN bronze.warehouse_stock_groups g ON g.StockGroupID = sg.StockGroupID;
    SET @n = @@ROWCOUNT;
    EXEC silver.usp_log 'stock_item_groups', @n, @t;

    SET @t = SYSDATETIME();
    DROP TABLE IF EXISTS silver.stock_item_transactions;
    SELECT  t.StockItemTransactionID AS stock_item_transaction_id,
            t.StockItemID AS stock_item_id,
            tt.TransactionTypeName AS transaction_type,
            t.CustomerID AS customer_id, t.InvoiceID AS invoice_id,
            t.SupplierID AS supplier_id, t.PurchaseOrderID AS purchase_order_id,
            t.TransactionOccurredWhen AS occurred_at,
            CAST(t.TransactionOccurredWhen AS DATE) AS occurred_date,
            CAST(t.Quantity AS DECIMAL(18,3)) AS quantity
    INTO silver.stock_item_transactions
    FROM bronze.warehouse_stock_item_transactions t
    JOIN bronze.application_transaction_types tt ON tt.TransactionTypeID = t.TransactionTypeID;
    SET @n = @@ROWCOUNT;
    EXEC silver.usp_log 'stock_item_transactions', @n, @t;

    /* ---------- Purchasing ---------- */
    SET @t = SYSDATETIME();
    DROP TABLE IF EXISTS silver.purchase_order_lines;
    SELECT  pol.PurchaseOrderLineID AS purchase_order_line_id,
            po.PurchaseOrderID AS purchase_order_id,
            po.SupplierID AS supplier_id,
            s.SupplierName AS supplier_name,
            pol.StockItemID AS stock_item_id,
            CAST(po.OrderDate AS DATE) AS order_date,
            CAST(po.ExpectedDeliveryDate AS DATE) AS expected_delivery_date,
            CAST(pol.LastReceiptDate AS DATE) AS last_receipt_date,
            pol.OrderedOuters AS ordered_outers,
            pol.ReceivedOuters AS received_outers,
            CAST(pol.ExpectedUnitPricePerOuter AS DECIMAL(18,2)) AS expected_unit_price_per_outer,
            CAST(pol.IsOrderLineFinalized AS BIT) AS is_finalized,
            DATEDIFF(DAY, po.OrderDate, pol.LastReceiptDate)     AS actual_lead_days,
            DATEDIFF(DAY, po.OrderDate, po.ExpectedDeliveryDate) AS expected_lead_days,
            CASE WHEN pol.LastReceiptDate IS NULL THEN 1 ELSE 0 END AS dq_no_receipt
    INTO silver.purchase_order_lines
    FROM bronze.purchasing_purchase_order_lines pol
    JOIN bronze.purchasing_purchase_orders po ON po.PurchaseOrderID = pol.PurchaseOrderID
    LEFT JOIN bronze.purchasing_suppliers s   ON s.SupplierID = po.SupplierID;
    SET @n = @@ROWCOUNT;
    EXEC silver.usp_log 'purchase_order_lines', @n, @t;

    SET @t = SYSDATETIME();
    DROP TABLE IF EXISTS silver.suppliers;
    SELECT  s.SupplierID AS supplier_id, LTRIM(RTRIM(s.SupplierName)) AS supplier_name,
            sc.SupplierCategoryName AS supplier_category, s.PaymentDays AS payment_days,
            s.DeliveryCityID AS delivery_city_id
    INTO silver.suppliers
    FROM bronze.purchasing_suppliers s
    LEFT JOIN bronze.purchasing_supplier_categories sc ON sc.SupplierCategoryID = s.SupplierCategoryID;
    SET @n = @@ROWCOUNT;
    EXEC silver.usp_log 'suppliers', @n, @t;

    SET @t = SYSDATETIME();
    DROP TABLE IF EXISTS silver.delivery_methods;
    SELECT DeliveryMethodID AS delivery_method_id, DeliveryMethodName AS delivery_method_name
    INTO silver.delivery_methods FROM bronze.application_delivery_methods;
    SET @n = @@ROWCOUNT;
    EXEC silver.usp_log 'delivery_methods', @n, @t;
    END TRY
    BEGIN CATCH
        INSERT INTO etl.load_log (layer, object_name, load_type, finished_at, status, error_message)
        VALUES ('silver', 'usp_load_silver', 'full', SYSDATETIME(), 'failed', ERROR_MESSAGE());
    END CATCH

    SELECT log_id, object_name, rows_affected, status, error_message
    FROM etl.load_log WHERE log_id >= @first_log ORDER BY log_id;
END
GO
