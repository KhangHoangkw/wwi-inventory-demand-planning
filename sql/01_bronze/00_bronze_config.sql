/* =====================================================================
   00_bronze_config.sql
   Metadata-driven bronze layer: one row per source table to copy.
   - pk_col        : single-column key used for incremental upsert
   - watermark_col : column used to detect changed rows (LastEditedWhen for transactional tables,
                     ValidFrom for system-versioned temporal tables);
                     NULL => always full reload (e.g. temporal history tables)
   Columns of type geography / varbinary are skipped automatically.
   ===================================================================== */
USE WWI_Analytics;
GO
IF OBJECT_ID('etl.bronze_config') IS NULL
CREATE TABLE etl.bronze_config (
    source_schema  SYSNAME NOT NULL,
    source_table   SYSNAME NOT NULL,
    bronze_table   SYSNAME NOT NULL,
    pk_col         SYSNAME NULL,
    watermark_col  SYSNAME NULL,
    is_active      BIT     NOT NULL DEFAULT 1,
    CONSTRAINT PK_bronze_config PRIMARY KEY (source_schema, source_table)
);
GO
DELETE FROM etl.bronze_config;
INSERT INTO etl.bronze_config (source_schema, source_table, bronze_table, pk_col, watermark_col) VALUES
 ('Sales','Orders','sales_orders','OrderID','LastEditedWhen'),
 ('Sales','OrderLines','sales_order_lines','OrderLineID','LastEditedWhen'),
 ('Sales','Invoices','sales_invoices','InvoiceID','LastEditedWhen'),
 ('Sales','InvoiceLines','sales_invoice_lines','InvoiceLineID','LastEditedWhen'),
 ('Sales','Customers','sales_customers','CustomerID','ValidFrom'),
 ('Sales','Customers_Archive','sales_customers_archive',NULL,NULL),
 ('Sales','CustomerCategories','sales_customer_categories','CustomerCategoryID','ValidFrom'),
 ('Sales','BuyingGroups','sales_buying_groups','BuyingGroupID','ValidFrom'),
 ('Purchasing','PurchaseOrders','purchasing_purchase_orders','PurchaseOrderID','LastEditedWhen'),
 ('Purchasing','PurchaseOrderLines','purchasing_purchase_order_lines','PurchaseOrderLineID','LastEditedWhen'),
 ('Purchasing','Suppliers','purchasing_suppliers','SupplierID','ValidFrom'),
 ('Purchasing','SupplierCategories','purchasing_supplier_categories','SupplierCategoryID','ValidFrom'),
 ('Warehouse','StockItems','warehouse_stock_items','StockItemID','ValidFrom'),
 ('Warehouse','StockItems_Archive','warehouse_stock_items_archive',NULL,NULL),
 ('Warehouse','StockItemHoldings','warehouse_stock_item_holdings','StockItemID','LastEditedWhen'),
 ('Warehouse','StockItemTransactions','warehouse_stock_item_transactions','StockItemTransactionID','LastEditedWhen'),
 ('Warehouse','StockGroups','warehouse_stock_groups','StockGroupID','ValidFrom'),
 ('Warehouse','StockItemStockGroups','warehouse_stock_item_stock_groups','StockItemStockGroupID','LastEditedWhen'),
 ('Warehouse','PackageTypes','warehouse_package_types','PackageTypeID','ValidFrom'),
 ('Warehouse','Colors','warehouse_colors','ColorID','ValidFrom'),
 ('Application','Cities','application_cities','CityID','ValidFrom'),
 ('Application','StateProvinces','application_state_provinces','StateProvinceID','ValidFrom'),
 ('Application','Countries','application_countries','CountryID','ValidFrom'),
 ('Application','DeliveryMethods','application_delivery_methods','DeliveryMethodID','ValidFrom'),
 ('Application','TransactionTypes','application_transaction_types','TransactionTypeID','ValidFrom');
GO
