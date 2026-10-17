/* =====================================================================
   00_profile_source.sql  -- run FIRST, right after restoring the .bak
   Goal: confirm date range, row counts and key columns before designing.
   Record the results in docs/data_profile.md
   ===================================================================== */
USE WideWorldImporters;
GO
-- 1. Date range of the business data
SELECT 'Sales.Orders'              AS tbl, MIN(OrderDate) AS min_d, MAX(OrderDate) AS max_d, COUNT(*) AS n FROM Sales.Orders
UNION ALL SELECT 'Sales.Invoices',          MIN(InvoiceDate), MAX(InvoiceDate), COUNT(*) FROM Sales.Invoices
UNION ALL SELECT 'Purchasing.PurchaseOrders', MIN(OrderDate), MAX(OrderDate), COUNT(*) FROM Purchasing.PurchaseOrders
UNION ALL SELECT 'Warehouse.StockItemTransactions', MIN(CAST(TransactionOccurredWhen AS date)), MAX(CAST(TransactionOccurredWhen AS date)), COUNT(*) FROM Warehouse.StockItemTransactions;

-- 2. Size of every table in the 3 business schemas
SELECT s.name AS schema_name, t.name AS table_name, SUM(p.rows) AS row_count
FROM sys.tables t
JOIN sys.schemas s    ON s.schema_id = t.schema_id
JOIN sys.partitions p ON p.object_id = t.object_id AND p.index_id IN (0,1)
WHERE s.name IN ('Sales','Purchasing','Warehouse','Application')
GROUP BY s.name, t.name
ORDER BY s.name, row_count DESC;

-- 3. Backorders: how many orders were split?
SELECT COUNT(*) AS orders, SUM(CASE WHEN BackorderOrderID IS NOT NULL THEN 1 ELSE 0 END) AS orders_with_backorder
FROM Sales.Orders;

-- 4. Inventory policy fields available per item
SELECT TOP 20 si.StockItemName, si.LeadTimeDays, si.QuantityPerOuter, si.IsChillerStock,
       h.QuantityOnHand, h.ReorderLevel, h.TargetStockLevel, h.LastCostPrice
FROM Warehouse.StockItems si
JOIN Warehouse.StockItemHoldings h ON h.StockItemID = si.StockItemID;

-- 5. Transaction types moving stock
SELECT tt.TransactionTypeName, COUNT(*) AS n, SUM(sit.Quantity) AS qty
FROM Warehouse.StockItemTransactions sit
JOIN Application.TransactionTypes tt ON tt.TransactionTypeID = sit.TransactionTypeID
GROUP BY tt.TransactionTypeName;
