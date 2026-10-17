# Data profile: WideWorldImporters (source OLTP)

Profiled with `sql/00_setup/00_profile_source.sql` and `02_profile_deep.sql`.

## 1. Date range
All business tables cover **2013-01-01 → 2016-05-31** (41 full months, May 2016 is complete).

| Table | Rows |
|---|---|
| Warehouse.StockItemTransactions | 236,667 |
| Sales.Orders | 73,595 |
| Sales.Invoices | 70,510 |
| Purchasing.PurchaseOrders | 2,074 |

## 2. Table sizes (business tables used in this project)
| Schema | Table | Rows | Use |
|---|---|---|---|
| Sales | OrderLines | 231,412 | demand (ordered qty) |
| Sales | InvoiceLines | 228,265 | shipped qty, revenue, profit |
| Sales | CustomerTransactions | 97,147 | (not needed) |
| Sales | Customers | 663 | dim_customer |
| Purchasing | PurchaseOrderLines | 8,367 | supplier OTIF, lead time |
| Purchasing | Suppliers | 13 | dim_supplier |
| Warehouse | StockItemTransactions | 236,667 | inventory movements → daily snapshot |
| Warehouse | StockItems / StockItemHoldings | 227 / 227 | dim_stock_item, current on hand, policy fields |
| Warehouse | StockItems_Archive | 444 | temporal history → SCD Type 2 |
| Warehouse | StockGroups / StockItemStockGroups | 10 / 442 | item ↔ group (many-to-many) |
| Application | TransactionTypes | 13 | movement type lookup |

Excluded: `ColdRoomTemperatures_Archive` (3.65M sensor rows) and `VehicleTemperatures`: IoT data, not in scope.

## 3. Backorders
7,538 of 73,595 orders (**10.2%**) have a backorder → enough volume for backorder / fill-rate analysis (Q6).

## 4. Inventory policy fields
- Every item has `LeadTimeDays` (sample: 12–14 days), `ReorderLevel`, `TargetStockLevel`, `LastCostPrice`.
- **QuantityOnHand is 50k–410k units** while ReorderLevel is 5–20 and TargetStockLevel 40–200.
  The policy fields are clearly not on the same scale as real stock. Must check against demand before trusting them
  (see `02_profile_deep.sql`). Possible outcomes:
  - on hand is huge vs demand → the story becomes **excess stock / days of supply** analysis;
  - or the policy fields are placeholders → recompute SS/ROP from demand and present the gap.

## 5. Transaction types (stock movements)
| Type | Rows | Total qty |
|---|---|---|
| Stock Issue (10) | 228,265 | −8,950,628 |
| Stock Receipt (11) | 8,358 | +139,418,326 |
| Stock Adjustment at Stocktake (12) | 44 | −18 |

Every stock issue row has an InvoiceID and the issue total equals Σ OrderLines.PickedQuantity exactly → issues = shipments.

## 6. Deep profiling results

### Demand side: realistic
- Monthly units ordered: ~144k–282k. Annual units 2013 ≈ 2.47M → 2015 ≈ 2.87M (**≈ +8%/yr**); Jan–May 2016 vs Jan–May 2015 **+8.8%**.
- Clear seasonality: **February is the low month every year**, July the peak in 2013–2015.
- Unit fill rate: picked 8,950,628 / ordered 9,310,904 = **96.1%**; 3,147 order lines short-picked.
- Backorders: 7,538 orders (10.2%) spawned a backorder order, **same day**, covering 124 distinct SKUs.
- Customer delivery: avg order → confirmed delivery **5.3 days**; 4,470 of 70,426 delivered invoices (**6.3%**) arrived after the order's ExpectedDeliveryDate; 84 invoices have no delivery confirmation.

### Supply / inventory side: not realistic (simulation artefacts)
1. **Receipts are concentrated in 9 SKUs**: those 9 SKUs received 139.39M units (99.98% of all receipts) vs 0.38M issued (>360× issues).
   The other **218 SKUs received only 25,509 units in 41 months but shipped 8.57M units**.
2. Implied opening stock (on hand now − Σ movements) is **negative for 9 SKUs** (min −25.0M) → current QuantityOnHand is not consistent with the transaction history.
3. Days of supply from current stock: avg ≈ 10,900 days, max ≈ 92,800 days; 9 SKUs hold less than one lead time of demand.
4. Purchasing: 13 suppliers but only 7 ever ordered from; Fabrikam + Litware = 98% of PO lines.
   **Actual lead time ≈ 1.4 days vs expected ≈ 19 days; zero late PO lines** → supplier OTIF would be 100% (no story).
5. ReorderLevel 5–20 / TargetStockLevel 40–200 vs on hand 50k–410k → policy fields are placeholders.

### Item ↔ stock group
94 SKUs in 1 group, 51 in 2, 82 in 3 → many-to-many; need a bridge table or a "primary group" rule.

## 7. Design decisions taken from this profile
| Finding | Decision |
|---|---|
| Demand data is clean, growing, seasonal | Demand & forecast is the **core** of the project (SKU × month, MAPE/bias, seasonal models) |
| Stock history cannot be rebuilt reliably | Do **not** present historical stock as truth. Instead **simulate** inventory under a calculated (ROP, order-up-to) policy using real daily demand → service level vs average inventory trade-off |
| Lead time: declared 12–14+ days vs actual ~1.4 days | "Planning parameter audit": show how inflated lead times inflate safety stock; simulate with both |
| Supplier OTIF trivially 100% | Drop supplier OTIF page; keep a small lead-time audit section |
| Customer OTD 6.3% late, fill 96.1%, backorders 10.2% | Customer service page (OTD, fill rate, backorder drivers by SKU / stock group) |
| All anomalies above | Data-quality page + `etl.dq_result` checks, so the data is validated before it is trusted |

## 8. Findings while building the pipeline
- **Row-Level Security** on `Sales.Customers` (policy `FilterCustomersBySalesTerritoryRole`): non-territory users see 0 rows → fixed by adding the analytics login to the 9 "<Territory> Sales" roles (`sql/00_setup/05_grant_customer_rls_access.sql`), not by db_owner.
- 14 reference tables are **system-versioned temporal tables** (no `LastEditedWhen`; use `ValidFrom` as incremental watermark).
- Temporal history of `StockItems` (671 versions) contains **no change** in price, lead time, pack size or name → SCD Type 1 is sufficient.
- Backorder child orders are created the same day and contain the **lines that could not be supplied** (different lines than the parent) → total demand = all order lines, no double counting. 242 child orders were split again.
- **3,147 order lines never picked** (picked = 0, no completion time), spread over 2013–2016 → lost / unshipped demand.
- No orders on Sundays; Saturday ≈ half a weekday.
- 4,626 invoice lines sold **below cost** (negative LineProfit).
- **8 SKUs launched Jan 2016** (novelty chocolates) → no calibration history.
- Monthly demand is very smooth (CV ≈ 0.25 for every SKU); weekly CV 0.47–0.53 → XYZ is weakly informative.
- Actual supplier lead time: 1 day (74% of receipts), 2 days (7%), 3 days (18%).
- Service trend: unit fill rate 98.0% (2013) → 94.5% (2016), order-to-delivery 1.4 → 3.6 days, while orders grow ~9%/yr.
- After the RLS grant: 663 customers (Novelty Shop 459, Supermarket 58, Computer Store 51, Gift Store 48, Corporate 47; buying groups Tailspin 201, Wingtip 201, none 261). Service KPIs do not differ by buying group, customer category or sales territory → the service problem is product-driven.
