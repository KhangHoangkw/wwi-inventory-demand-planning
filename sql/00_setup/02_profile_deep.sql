/* =====================================================================
   02_profile_deep.sql -- second profiling pass (answers open questions
   in docs/data_profile.md). Run whole file (F5); 6 result grids.
   ===================================================================== */
USE WideWorldImporters;
GO
-- Q5 (repeat): which transaction types move stock, and in which direction
SELECT tt.TransactionTypeName, COUNT(*) AS n,
       SUM(sit.Quantity) AS total_qty,
       MIN(sit.Quantity) AS min_qty, MAX(sit.Quantity) AS max_qty
FROM Warehouse.StockItemTransactions sit
JOIN Application.TransactionTypes tt ON tt.TransactionTypeID = sit.TransactionTypeID
GROUP BY tt.TransactionTypeName;

-- A. Demand vs on hand: average daily ordered qty and days of supply (top 15 by DOS + summary)
WITH demand AS (
    SELECT ol.StockItemID,
           SUM(ol.Quantity) * 1.0 / DATEDIFF(DAY, '2013-01-01', '2016-05-31') AS avg_daily_demand
    FROM Sales.OrderLines ol
    GROUP BY ol.StockItemID
)
SELECT
    COUNT(*)                                        AS items,
    AVG(h.QuantityOnHand * 1.0)                     AS avg_on_hand,
    AVG(d.avg_daily_demand)                         AS avg_daily_demand,
    MIN(h.QuantityOnHand / NULLIF(d.avg_daily_demand,0)) AS min_dos,
    AVG(h.QuantityOnHand / NULLIF(d.avg_daily_demand,0)) AS avg_dos,
    MAX(h.QuantityOnHand / NULLIF(d.avg_daily_demand,0)) AS max_dos,
    SUM(CASE WHEN d.StockItemID IS NULL THEN 1 ELSE 0 END) AS items_never_ordered
FROM Warehouse.StockItemHoldings h
LEFT JOIN demand d ON d.StockItemID = h.StockItemID;

-- B. Purchasing coverage: POs per supplier, items bought, receipt info available
SELECT s.SupplierName,
       COUNT(DISTINCT po.PurchaseOrderID)            AS pos,
       COUNT(pol.PurchaseOrderLineID)                AS po_lines,
       COUNT(DISTINCT pol.StockItemID)               AS items,
       SUM(CASE WHEN pol.LastReceiptDate IS NULL THEN 1 ELSE 0 END) AS lines_no_receipt,
       SUM(CASE WHEN pol.ReceivedOuters < pol.OrderedOuters THEN 1 ELSE 0 END) AS lines_short,
       AVG(DATEDIFF(DAY, po.OrderDate, pol.LastReceiptDate) * 1.0) AS avg_actual_lead_days,
       AVG(DATEDIFF(DAY, po.OrderDate, po.ExpectedDeliveryDate) * 1.0) AS avg_expected_lead_days
FROM Purchasing.PurchaseOrders po
JOIN Purchasing.PurchaseOrderLines pol ON pol.PurchaseOrderID = po.PurchaseOrderID
JOIN Purchasing.Suppliers s ON s.SupplierID = po.SupplierID
GROUP BY s.SupplierName
ORDER BY pos DESC;

-- C. Monthly demand trend (orders, lines, units) for seasonality
SELECT FORMAT(o.OrderDate, 'yyyy-MM') AS ym,
       COUNT(DISTINCT o.OrderID) AS orders,
       COUNT(*)                  AS lines,
       SUM(ol.Quantity)          AS units
FROM Sales.Orders o
JOIN Sales.OrderLines ol ON ol.OrderID = o.OrderID
GROUP BY FORMAT(o.OrderDate, 'yyyy-MM')
ORDER BY ym;

-- D. Can we rebuild history? Opening stock implied = on hand now - sum of all movements
SELECT TOP 10 h.StockItemID, h.QuantityOnHand,
       SUM(sit.Quantity) AS net_movements,
       h.QuantityOnHand - SUM(sit.Quantity) AS implied_opening_stock_2013
FROM Warehouse.StockItemHoldings h
JOIN Warehouse.StockItemTransactions sit ON sit.StockItemID = h.StockItemID
GROUP BY h.StockItemID, h.QuantityOnHand
ORDER BY implied_opening_stock_2013;   -- negative values = data inconsistency to handle

-- E. Item ↔ stock group: how many groups per item (many-to-many check)
SELECT groups_per_item, COUNT(*) AS items
FROM (SELECT StockItemID, COUNT(*) AS groups_per_item
      FROM Warehouse.StockItemStockGroups GROUP BY StockItemID) x
GROUP BY groups_per_item;
