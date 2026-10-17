/* =====================================================================
   05_vw_policy_kpi.sql
   KPI views on top of gold.fact_policy_simulation (test year 2015-06..2016-05).
     gold.vw_policy_kpi_sku      : scenario x SKU
     gold.vw_policy_kpi_scenario : scenario totals = the service-vs-inventory frontier
   Definitions
     fill_rate         = units served from stock on the day of demand / units demanded
     ready_rate        = days with demand fully served from stock / days with demand
     avg_on_hand_value = average end-of-day on-hand units x last cost price
     target_gap        = fill_rate - target service level (negative = policy under-delivers)
     inventory_turns   = cost of units shipped in the year / average inventory value
     days_of_supply    = 366 / inventory_turns
   ===================================================================== */
USE WWI_Analytics;
GO
CREATE OR ALTER VIEW gold.vw_policy_kpi_sku
AS
SELECT  f.run_type, f.scenario_id, f.stock_item_id,
        c.abc_class, c.xyz_class,
        SUM(f.demand_qty)                                   AS demand_units,
        SUM(f.filled_qty)                                   AS filled_units,
        SUM(f.filled_qty) / NULLIF(SUM(f.demand_qty), 0)    AS fill_rate,
        SUM(CASE WHEN f.demand_qty > 0 AND f.filled_qty >= f.demand_qty THEN 1.0 ELSE 0 END)
          / NULLIF(SUM(CASE WHEN f.demand_qty > 0 THEN 1 ELSE 0 END), 0) AS ready_rate,
        AVG(f.on_hand_end)                                  AS avg_on_hand_units,
        AVG(f.on_hand_end) * i.last_cost_price              AS avg_on_hand_value,
        SUM(f.filled_qty) * i.last_cost_price               AS cogs_value,          -- cost of units shipped from stock
        SUM(CASE WHEN f.order_qty > 0 THEN 1 ELSE 0 END)    AS purchase_orders,
        MAX(f.backlog_end)                                  AS max_backlog_units
FROM gold.fact_policy_simulation f
JOIN gold.dim_stock_item i       ON i.stock_item_id = f.stock_item_id
JOIN gold.sku_classification c   ON c.stock_item_id = f.stock_item_id
GROUP BY f.run_type, f.scenario_id, f.stock_item_id, c.abc_class, c.xyz_class, i.last_cost_price;
GO
CREATE OR ALTER VIEW gold.vw_policy_kpi_scenario
AS
SELECT  k.run_type, k.scenario_id, s.scenario_name, s.lt_scenario, s.service_level,
        SUM(k.filled_units) / SUM(k.demand_units)  AS fill_rate,
        AVG(k.ready_rate)                           AS avg_sku_ready_rate,
        SUM(k.avg_on_hand_value)                    AS avg_inventory_value,
        SUM(k.avg_on_hand_units)                    AS avg_inventory_units,
        SUM(k.purchase_orders)                      AS purchase_orders,
        SUM(k.cogs_value) / NULLIF(SUM(k.avg_on_hand_value), 0)        AS inventory_turns,      -- test year = 366 days
        366.0 * SUM(k.avg_on_hand_value) / NULLIF(SUM(k.cogs_value), 0) AS days_of_supply,
        SUM(k.filled_units) / SUM(k.demand_units) - s.service_level AS target_gap,
        SUM(CASE WHEN k.fill_rate < s.service_level THEN 1 ELSE 0 END) AS skus_below_target
FROM gold.vw_policy_kpi_sku k
JOIN gold.dim_policy_scenario s ON s.scenario_id = k.scenario_id
GROUP BY k.run_type, k.scenario_id, s.scenario_name, s.lt_scenario, s.service_level;
GO
