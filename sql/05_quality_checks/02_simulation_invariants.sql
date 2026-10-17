/* =====================================================================
   02_simulation_invariants.sql  -- unit tests for gold.usp_simulate_policy
   Every count must be 0 (last run: all 0 over 3,723 scenario x SKU pairs).
     balance_violations  : start stock + receipts - demand <> ending net inventory
     pipeline_violations : units ordered - units received <> units still on order
     state_violations    : negative on hand / backlog, filled > demand, on hand and backlog at once
     pack_violations     : order quantity not a whole number of outers (QuantityPerOuter)
   ===================================================================== */
USE WWI_Analytics;
GO
WITH f AS (
    SELECT scenario_id, stock_item_id, SUM(receipt_qty) AS rec, SUM(demand_qty) AS dem, SUM(order_qty) AS ord,
           MAX(CASE WHEN date_key = 20160531 THEN net_inventory_end END) AS net_end,
           MAX(CASE WHEN date_key = 20160531 THEN on_order_end END)      AS oo_end
    FROM gold.fact_policy_simulation WHERE run_type = 'replay'
    GROUP BY scenario_id, stock_item_id),
p AS (SELECT scenario_id, stock_item_id, order_up_to AS s0 FROM gold.policy_parameters WHERE month_start = '2015-06-01')
SELECT COUNT(*) AS pairs,
       SUM(CASE WHEN ABS(p.s0 + f.rec - f.dem - f.net_end) > 0.001 THEN 1 ELSE 0 END) AS balance_violations,
       SUM(CASE WHEN ABS(f.ord - f.rec - f.oo_end) > 0.001 THEN 1 ELSE 0 END)         AS pipeline_violations,
       (SELECT COUNT(*) FROM gold.fact_policy_simulation
        WHERE on_hand_end < 0 OR backlog_end < 0 OR filled_qty > demand_qty
           OR (on_hand_end > 0 AND backlog_end > 0))                                  AS state_violations,
       (SELECT COUNT(*) FROM gold.fact_policy_simulation s
        JOIN gold.policy_parameters pp
          ON pp.scenario_id = s.scenario_id AND pp.stock_item_id = s.stock_item_id
         AND pp.month_start = DATEFROMPARTS(s.date_key / 10000, (s.date_key / 100) % 100, 1)
        WHERE s.order_qty > 0 AND CAST(s.order_qty AS INT) % pp.quantity_per_outer <> 0) AS pack_violations
FROM f JOIN p ON p.scenario_id = f.scenario_id AND p.stock_item_id = f.stock_item_id;
GO
