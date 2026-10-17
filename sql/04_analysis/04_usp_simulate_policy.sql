/* =====================================================================
   04_usp_simulate_policy.sql
   gold.usp_simulate_policy : day-by-day inventory simulation of every
   scenario x SKU on the REAL daily demand of the test year (2015-06-01 ..
   2016-05-31). Set-based inside each day: one loop iteration = one day for
   all scenarios x SKUs at once.  (Q3 / Q4)

   Daily sequence (continuous review, backorders allowed):
     1. receive orders whose arrival_date = today
     2. serve demand: filled = min(on hand, demand); unfilled demand becomes
        backlog (net inventory can go negative)
     3. inventory position = net inventory + on order
        if position <= ROP -> order up to S, rounded UP to whole outers,
        arrives today + lead time
     4. write one row per scenario x SKU x day to gold.fact_policy_simulation
   Start state (2015-06-01): net inventory = S of June, nothing on order.
   Resumable: state lives in gold.sim_state / gold.sim_pipeline, so the year
   can be run in monthly chunks (@reset = 1 only on the first chunk).
   run_type = 'replay' (this deterministic replay). A future Python bootstrap
   Monte Carlo can write to the same table with run_type = 'bootstrap'.
   ===================================================================== */
USE WWI_Analytics;
GO
CREATE OR ALTER PROCEDURE gold.usp_simulate_policy
    @from  DATE,
    @to    DATE,
    @reset BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @d DATE = @from, @t DATETIME2(0) = SYSDATETIME();

    IF @reset = 1
    BEGIN
        DROP TABLE IF EXISTS gold.sim_state;
        DROP TABLE IF EXISTS gold.sim_pipeline;
        CREATE TABLE gold.sim_state (
            scenario_id INT NOT NULL, stock_item_id INT NOT NULL, net_inventory FLOAT NOT NULL,
            CONSTRAINT PK_sim_state PRIMARY KEY (scenario_id, stock_item_id));
        CREATE TABLE gold.sim_pipeline (
            scenario_id INT NOT NULL, stock_item_id INT NOT NULL, arrival_date DATE NOT NULL, qty FLOAT NOT NULL);
        CREATE CLUSTERED INDEX CX_sim_pipeline ON gold.sim_pipeline (arrival_date, scenario_id, stock_item_id);

        IF OBJECT_ID('gold.fact_policy_simulation') IS NULL
            CREATE TABLE gold.fact_policy_simulation (
                run_type VARCHAR(20) NOT NULL, scenario_id INT NOT NULL, stock_item_id INT NOT NULL,
                date_key INT NOT NULL, demand_qty FLOAT NOT NULL, filled_qty FLOAT NOT NULL,
                receipt_qty FLOAT NOT NULL, order_qty FLOAT NOT NULL,
                net_inventory_end FLOAT NOT NULL, on_hand_end FLOAT NOT NULL, backlog_end FLOAT NOT NULL,
                on_order_end FLOAT NOT NULL,
                CONSTRAINT PK_fact_policy_simulation PRIMARY KEY (run_type, scenario_id, stock_item_id, date_key));
        DELETE FROM gold.fact_policy_simulation WHERE run_type = 'replay';

        INSERT INTO gold.sim_state (scenario_id, stock_item_id, net_inventory)
        SELECT scenario_id, stock_item_id, order_up_to
        FROM gold.policy_parameters WHERE month_start = DATEFROMPARTS(YEAR(@from), MONTH(@from), 1);
    END

    WHILE @d <= @to
    BEGIN
        /* 1. receipts */
        UPDATE s SET s.net_inventory = s.net_inventory + r.qty
        FROM gold.sim_state s
        JOIN (SELECT scenario_id, stock_item_id, SUM(qty) AS qty
              FROM gold.sim_pipeline WHERE arrival_date = @d
              GROUP BY scenario_id, stock_item_id) r
          ON r.scenario_id = s.scenario_id AND r.stock_item_id = s.stock_item_id;

        /* 2 + 3. demand, then reorder decision */
        DROP TABLE IF EXISTS #x;
        SELECT s.scenario_id, s.stock_item_id,
               ISNULL(rc.qty, 0) AS receipt_qty,
               dm.demand_qty,
               CASE WHEN s.net_inventory <= 0 THEN 0
                    WHEN s.net_inventory < dm.demand_qty THEN s.net_inventory
                    ELSE dm.demand_qty END AS filled_qty,
               s.net_inventory - dm.demand_qty AS net_after,
               ISNULL(po.qty, 0) AS on_order,
               p.reorder_point, p.order_up_to, p.lt_days, p.quantity_per_outer
        INTO #x
        FROM gold.sim_state s
        JOIN gold.fact_demand_daily dm
          ON dm.stock_item_id = s.stock_item_id AND dm.[date] = @d
        JOIN gold.policy_parameters p
          ON p.scenario_id = s.scenario_id AND p.stock_item_id = s.stock_item_id
         AND p.month_start = DATEFROMPARTS(YEAR(@d), MONTH(@d), 1)
        LEFT JOIN (SELECT scenario_id, stock_item_id, SUM(qty) AS qty FROM gold.sim_pipeline
                   WHERE arrival_date = @d GROUP BY scenario_id, stock_item_id) rc
          ON rc.scenario_id = s.scenario_id AND rc.stock_item_id = s.stock_item_id
        LEFT JOIN (SELECT scenario_id, stock_item_id, SUM(qty) AS qty FROM gold.sim_pipeline
                   WHERE arrival_date > @d GROUP BY scenario_id, stock_item_id) po
          ON po.scenario_id = s.scenario_id AND po.stock_item_id = s.stock_item_id;

        ALTER TABLE #x ADD order_qty FLOAT NULL;
        UPDATE #x SET order_qty =
            CASE WHEN net_after + on_order <= reorder_point
                 THEN CEILING(CASE WHEN order_up_to - (net_after + on_order) > 0
                                   THEN order_up_to - (net_after + on_order) ELSE 1 END
                              / quantity_per_outer) * quantity_per_outer
                 ELSE 0 END;

        DELETE FROM gold.sim_pipeline WHERE arrival_date <= @d;

        UPDATE s SET s.net_inventory = x.net_after
        FROM gold.sim_state s JOIN #x x ON x.scenario_id = s.scenario_id AND x.stock_item_id = s.stock_item_id;

        INSERT INTO gold.sim_pipeline (scenario_id, stock_item_id, arrival_date, qty)
        SELECT scenario_id, stock_item_id, DATEADD(DAY, lt_days, @d), order_qty FROM #x WHERE order_qty > 0;

        /* 4. results */
        INSERT INTO gold.fact_policy_simulation
            (run_type, scenario_id, stock_item_id, date_key, demand_qty, filled_qty, receipt_qty, order_qty,
             net_inventory_end, on_hand_end, backlog_end, on_order_end)
        SELECT 'replay', scenario_id, stock_item_id, CAST(CONVERT(CHAR(8), @d, 112) AS INT),
               demand_qty, filled_qty, receipt_qty, order_qty,
               net_after,
               CASE WHEN net_after > 0 THEN net_after ELSE 0 END,
               CASE WHEN net_after < 0 THEN -net_after ELSE 0 END,
               on_order + order_qty
        FROM #x;

        SET @d = DATEADD(DAY, 1, @d);
    END

    INSERT INTO etl.load_log (layer, object_name, load_type, rows_affected, started_at, finished_at, status)
    VALUES ('gold', CONCAT('simulate ', @from, '..', @to), 'replay',
            DATEDIFF(DAY, @from, @to) + 1, @t, SYSDATETIME(), 'success');

    SELECT CONCAT(@from, '..', @to) AS chunk, COUNT(*) AS rows_in_table,
           DATEDIFF(SECOND, @t, SYSDATETIME()) AS seconds
    FROM gold.fact_policy_simulation WHERE run_type = 'replay';
END
GO
