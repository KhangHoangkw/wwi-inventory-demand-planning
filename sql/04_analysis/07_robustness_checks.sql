/* =====================================================================
   07_robustness_checks.sql
   How much should we trust the headline results?  Three checks that go
   beyond "one test year, one simulated path":

   1. Forecast, month by month: which model has the lowest WAPE in each month.
      Only months from 2015-01 are fully out-of-sample for SEAS (its seasonal
      index uses 2013-2014), so 2014 wins are reported separately.
   2. SKU bootstrap (1,000 resamples of the 219 SKUs, with replacement):
      confidence intervals for (a) the WAPE gap between models and
      (b) the inventory / fill-rate gap between two policies.
      The draws are deterministic (SHA-256 of rep and draw number), so the
      results are reproducible.  This captures uncertainty from the SKU mix,
      not from a different demand path (that needs the Monte Carlo extension).
   3. Policy comparison month by month and SKU by SKU: does the actual-LT
      policy beat the declared-LT policy in every month / for most SKUs?

   Output: gold.robustness_result (one row per metric) + two views.
   ===================================================================== */
USE WWI_Analytics;
GO
/* ---------- 0. bootstrap draws (1,000 reps x 250 draws), built once ---------- */
IF OBJECT_ID('gold.bootstrap_draws') IS NULL
BEGIN
    WITH nums AS (SELECT TOP (1000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i
                  FROM sys.all_objects a CROSS JOIN sys.all_objects b)
    SELECT CAST(r.i AS SMALLINT) AS rep, CAST(d.i AS SMALLINT) AS k,
           ABS(CAST(SUBSTRING(HASHBYTES('SHA2_256', CONCAT('wwi-', r.i, '-', d.i)), 1, 4) AS INT)) AS h
    INTO gold.bootstrap_draws
    FROM nums r CROSS JOIN (SELECT TOP (250) i FROM nums) d;
    CREATE UNIQUE CLUSTERED INDEX UX_bootstrap_draws ON gold.bootstrap_draws (rep, k);
END
GO
/* ---------- 1. monthly forecast accuracy by model ---------- */
CREATE OR ALTER VIEW gold.vw_forecast_accuracy_monthly
AS
SELECT  m.month_start, m.model, m.wape, m.bias,
        CASE WHEN m.month_start >= '2015-06-01' THEN 'test'
             WHEN m.month_start >= '2015-01-01' THEN 'calibration (season index out-of-sample)'
             ELSE 'calibration 2014 (season index in-sample)' END AS window_,
        RANK() OVER (PARTITION BY m.month_start ORDER BY m.wape) AS rank_in_month
FROM (
    SELECT f.month_start, f.model,
           SUM(f.abs_error_units) / SUM(CAST(f.actual_units AS FLOAT)) AS wape,
           SUM(f.error_units)     / SUM(CAST(f.actual_units AS FLOAT)) AS bias
    FROM gold.fact_forecast f
    WHERE f.month_start >= '2014-01-01'
    GROUP BY f.month_start, f.model) m;
GO
/* ---------- 3. policy KPIs by month (for the month-by-month comparison) ---------- */
CREATE OR ALTER VIEW gold.vw_policy_kpi_monthly
AS
SELECT  f.run_type, f.scenario_id, d.month_start,
        SUM(f.filled_qty) / NULLIF(SUM(f.demand_qty), 0) AS fill_rate,
        SUM(f.on_hand_end * i.last_cost_price) / COUNT(DISTINCT f.date_key) AS avg_inventory_value
FROM gold.fact_policy_simulation f
JOIN gold.dim_date d        ON d.date_key = f.date_key
JOIN gold.dim_stock_item i  ON i.stock_item_id = f.stock_item_id
GROUP BY f.run_type, f.scenario_id, d.month_start;
GO
CREATE OR ALTER PROCEDURE gold.usp_robustness_checks
    @policy_a INT = 12,   -- actual 3d LT, CSL 99%   (recommended)
    @policy_b INT = 2     -- declared LT,  CSL 95%   (current practice)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t DATETIME2(0) = SYSDATETIME();
    DROP TABLE IF EXISTS gold.robustness_result;
    CREATE TABLE gold.robustness_result (
        check_group VARCHAR(40), metric VARCHAR(120), value FLOAT, ci_low FLOAT, ci_high FLOAT, note VARCHAR(200));

    /* 1. forecast: monthly wins, out-of-sample months only (2015-01 .. 2016-05) */
    INSERT gold.robustness_result (check_group, metric, value, note)
    SELECT 'forecast monthly', model + ' months ranked best (of 17)',
           SUM(CASE WHEN rank_in_month = 1 THEN 1 ELSE 0 END), '2015-01..2016-05, all models out-of-sample'
    FROM gold.vw_forecast_accuracy_monthly
    WHERE month_start >= '2015-01-01'
    GROUP BY model;

    /* 2a. forecast: SKU bootstrap of test-year WAPE */
    CREATE TABLE #bs_fc (rep INT, w_seas FLOAT, w_ma3 FLOAT, w_sn FLOAT);
    WITH sku AS (
        SELECT stock_item_id,
               SUM(CASE WHEN model = 'SEAS'   THEN abs_error_units END) AS e_seas,
               SUM(CASE WHEN model = 'MA3'    THEN abs_error_units END) AS e_ma3,
               SUM(CASE WHEN model = 'SNAIVE' THEN abs_error_units END) AS e_sn,
               SUM(CASE WHEN model = 'SEAS'   THEN CAST(actual_units AS FLOAT) END) AS a
        FROM gold.fact_forecast WHERE month_start >= '2015-06-01'
        GROUP BY stock_item_id),
    n AS (SELECT *, ROW_NUMBER() OVER (ORDER BY stock_item_id) AS rn, COUNT(*) OVER () AS cnt FROM sku)
    INSERT #bs_fc (rep, w_seas, w_ma3, w_sn)
    SELECT b.rep, SUM(n.e_seas) / SUM(n.a), SUM(n.e_ma3) / SUM(n.a), SUM(n.e_sn) / SUM(n.a)
    FROM gold.bootstrap_draws b
    JOIN n ON n.rn = b.h % n.cnt + 1
    WHERE b.k <= (SELECT COUNT(*) FROM sku)
    GROUP BY b.rep;

    INSERT gold.robustness_result
    SELECT DISTINCT 'forecast bootstrap', 'WAPE MA3 - SEAS (test year, pts)',
           NULL, PERCENTILE_CONT(0.025) WITHIN GROUP (ORDER BY w_ma3 - w_seas) OVER (),
           PERCENTILE_CONT(0.975) WITHIN GROUP (ORDER BY w_ma3 - w_seas) OVER (), '95% CI, 1,000 SKU resamples'
    FROM #bs_fc
    UNION ALL
    SELECT DISTINCT 'forecast bootstrap', 'WAPE SNAIVE - SEAS (test year, pts)',
           NULL, PERCENTILE_CONT(0.025) WITHIN GROUP (ORDER BY w_sn - w_seas) OVER (),
           PERCENTILE_CONT(0.975) WITHIN GROUP (ORDER BY w_sn - w_seas) OVER (), '95% CI, 1,000 SKU resamples'
    FROM #bs_fc
    UNION ALL
    SELECT DISTINCT 'forecast bootstrap', 'WAPE SEAS (test year)',
           NULL, PERCENTILE_CONT(0.025) WITHIN GROUP (ORDER BY w_seas) OVER (),
           PERCENTILE_CONT(0.975) WITHIN GROUP (ORDER BY w_seas) OVER (), '95% CI, 1,000 SKU resamples'
    FROM #bs_fc;

    UPDATE r SET value = x.v
    FROM gold.robustness_result r
    CROSS APPLY (SELECT CASE r.metric
                    WHEN 'WAPE MA3 - SEAS (test year, pts)'    THEN (SELECT SUM(CASE WHEN model='MA3' THEN abs_error_units END)/SUM(CASE WHEN model='MA3' THEN CAST(actual_units AS FLOAT) END)
                                                                             - SUM(CASE WHEN model='SEAS' THEN abs_error_units END)/SUM(CASE WHEN model='SEAS' THEN CAST(actual_units AS FLOAT) END)
                                                                      FROM gold.fact_forecast WHERE month_start >= '2015-06-01')
                    WHEN 'WAPE SNAIVE - SEAS (test year, pts)' THEN (SELECT SUM(CASE WHEN model='SNAIVE' THEN abs_error_units END)/SUM(CASE WHEN model='SNAIVE' THEN CAST(actual_units AS FLOAT) END)
                                                                             - SUM(CASE WHEN model='SEAS' THEN abs_error_units END)/SUM(CASE WHEN model='SEAS' THEN CAST(actual_units AS FLOAT) END)
                                                                      FROM gold.fact_forecast WHERE month_start >= '2015-06-01')
                    WHEN 'WAPE SEAS (test year)'               THEN (SELECT SUM(CASE WHEN model='SEAS' THEN abs_error_units END)/SUM(CASE WHEN model='SEAS' THEN CAST(actual_units AS FLOAT) END)
                                                                      FROM gold.fact_forecast WHERE month_start >= '2015-06-01')
                 END AS v) x
    WHERE r.check_group = 'forecast bootstrap';

    /* 2b/3. policy A vs policy B: SKU-level and month-level KPIs, computed once */
    CREATE TABLE #k (scenario_id INT, stock_item_id INT, demand_units FLOAT, filled_units FLOAT, avg_on_hand_value FLOAT);
    INSERT #k
    SELECT f.scenario_id, f.stock_item_id,
           SUM(f.demand_qty), SUM(f.filled_qty),
           AVG(f.on_hand_end) * MAX(i.last_cost_price)
    FROM gold.fact_policy_simulation f
    JOIN gold.dim_stock_item i ON i.stock_item_id = f.stock_item_id
    WHERE f.run_type = 'replay' AND f.scenario_id IN (@policy_a, @policy_b)
    GROUP BY f.scenario_id, f.stock_item_id;

    CREATE TABLE #m (scenario_id INT, month_start DATE, fill_rate FLOAT, avg_inventory_value FLOAT);
    INSERT #m
    SELECT f.scenario_id, d.month_start,
           SUM(f.filled_qty) / NULLIF(SUM(f.demand_qty), 0),
           SUM(f.on_hand_end * i.last_cost_price) / COUNT(DISTINCT f.date_key)
    FROM gold.fact_policy_simulation f
    JOIN gold.dim_date d       ON d.date_key = f.date_key
    JOIN gold.dim_stock_item i ON i.stock_item_id = f.stock_item_id
    WHERE f.run_type = 'replay' AND f.scenario_id IN (@policy_a, @policy_b)
    GROUP BY f.scenario_id, d.month_start;

    CREATE TABLE #kp (stock_item_id INT, fa FLOAT, fb FLOAT, d FLOAT, ia FLOAT, ib FLOAT, rn INT, cnt INT);
    WITH k AS (
        SELECT stock_item_id,
               SUM(CASE WHEN scenario_id = @policy_a THEN filled_units END)      AS fa,
               SUM(CASE WHEN scenario_id = @policy_b THEN filled_units END)      AS fb,
               SUM(CASE WHEN scenario_id = @policy_a THEN demand_units END)      AS d,
               SUM(CASE WHEN scenario_id = @policy_a THEN avg_on_hand_value END) AS ia,
               SUM(CASE WHEN scenario_id = @policy_b THEN avg_on_hand_value END) AS ib
        FROM #k GROUP BY stock_item_id)
    INSERT #kp
    SELECT stock_item_id, fa, fb, d, ia, ib, ROW_NUMBER() OVER (ORDER BY stock_item_id), COUNT(*) OVER () FROM k;

    CREATE TABLE #bs_pol (rep INT, d_fill FLOAT, d_inv FLOAT);
    INSERT #bs_pol
    SELECT b.rep, SUM(n.fa) / SUM(n.d) - SUM(n.fb) / SUM(n.d),
           SUM(n.ia) / SUM(n.ib) - 1
    FROM gold.bootstrap_draws b
    JOIN #kp n ON n.rn = b.h % n.cnt + 1
    WHERE b.k <= (SELECT COUNT(*) FROM #kp)
    GROUP BY b.rep;

    INSERT gold.robustness_result
    SELECT DISTINCT 'policy bootstrap', CONCAT('fill rate S', @policy_a, ' - S', @policy_b, ' (pts)'),
           (SELECT SUM(fa) / SUM(d) - SUM(fb) / SUM(d) FROM #kp),
           PERCENTILE_CONT(0.025) WITHIN GROUP (ORDER BY d_fill) OVER (),
           PERCENTILE_CONT(0.975) WITHIN GROUP (ORDER BY d_fill) OVER (), '95% CI, 1,000 SKU resamples'
    FROM #bs_pol
    UNION ALL
    SELECT DISTINCT 'policy bootstrap', CONCAT('avg inventory value S', @policy_a, ' vs S', @policy_b, ' (relative)'),
           (SELECT SUM(ia) / SUM(ib) - 1 FROM #kp),
           PERCENTILE_CONT(0.025) WITHIN GROUP (ORDER BY d_inv) OVER (),
           PERCENTILE_CONT(0.975) WITHIN GROUP (ORDER BY d_inv) OVER (), '95% CI, 1,000 SKU resamples'
    FROM #bs_pol;

    INSERT gold.robustness_result (check_group, metric, value, note)
    SELECT 'policy by month', CONCAT('months S', @policy_a, ' has lower inventory than S', @policy_b, ' (of 12)'),
           SUM(CASE WHEN a.avg_inventory_value < b.avg_inventory_value THEN 1 ELSE 0 END), 'test year'
    FROM #m a JOIN #m b ON b.month_start = a.month_start AND b.scenario_id = @policy_b
    WHERE a.scenario_id = @policy_a
    UNION ALL
    SELECT 'policy by month', CONCAT('months S', @policy_a, ' fill rate >= S', @policy_b, ' (of 12)'),
           SUM(CASE WHEN a.fill_rate >= b.fill_rate THEN 1 ELSE 0 END), 'test year'
    FROM #m a JOIN #m b ON b.month_start = a.month_start AND b.scenario_id = @policy_b
    WHERE a.scenario_id = @policy_a
    UNION ALL
    SELECT 'policy by month', CONCAT('lowest monthly fill rate S', scenario_id), MIN(fill_rate), 'test year'
    FROM #m GROUP BY scenario_id;

    INSERT gold.robustness_result (check_group, metric, value, note)
    SELECT 'policy by SKU', CONCAT('share of SKUs where S', @policy_a, ' holds less inventory than S', @policy_b),
           AVG(CASE WHEN ia < ib THEN 1.0 ELSE 0 END), CONCAT(COUNT(*), ' SKUs')
    FROM #kp
    UNION ALL
    SELECT 'policy by SKU', CONCAT('share of SKUs where S', @policy_a, ' fill rate >= S', @policy_b),
           AVG(CASE WHEN fa >= fb THEN 1.0 ELSE 0 END), CONCAT(COUNT(*), ' SKUs')
    FROM #kp;

    DECLARE @n INT = (SELECT COUNT(*) FROM gold.robustness_result);
    EXEC silver.usp_log 'gold.robustness_result', @n, @t;
    SELECT * FROM gold.robustness_result ORDER BY check_group, metric;
END
GO
/* ---------- formatted view for the report ----------
   S12 = actual 3d LT, CSL 99% (recommended) ; S2 = declared LT, CSL 95% (current practice) */
CREATE OR ALTER VIEW gold.vw_robustness_result
AS
SELECT  check_group,
        REPLACE(REPLACE(metric, 'S12', 'recommended (S12)'), 'S2', 'current (S2)') AS metric,
        value, ci_low, ci_high, note,
        CASE WHEN metric LIKE '%pts)%'       THEN FORMAT(value * 100, '+0.0;-0.0') + ' pts'
             WHEN metric LIKE '%(relative)%' THEN FORMAT(value, '+0.0%;-0.0%')
             WHEN metric LIKE 'share%' OR metric LIKE 'lowest%' OR metric LIKE 'WAPE SEAS%' THEN FORMAT(value, '0.0%')
             ELSE FORMAT(value, '0') END AS value_text,
        CASE WHEN ci_low IS NULL THEN NULL
             WHEN metric LIKE '%pts)%'       THEN CONCAT('[', FORMAT(ci_low * 100, '+0.0;-0.0'), ', ', FORMAT(ci_high * 100, '+0.0;-0.0'), '] pts')
             WHEN metric LIKE '%(relative)%' THEN CONCAT('[', FORMAT(ci_low, '+0.0%;-0.0%'), ', ', FORMAT(ci_high, '+0.0%;-0.0%'), ']')
             ELSE CONCAT('[', FORMAT(ci_low, '0.0%'), ', ', FORMAT(ci_high, '0.0%'), ']') END AS ci_95_text
FROM gold.robustness_result;
GO
