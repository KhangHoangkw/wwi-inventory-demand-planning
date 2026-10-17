/* =====================================================================
   03_usp_build_policy_parameters.sql
   gold.usp_build_policy_parameters : replenishment parameters per
   scenario x SKU x test month (rolling monthly, like a planner would).   (Q3/Q4)

   Scenarios = service level {90, 95, 97.5, 99%} x lead time {declared per SKU,
               7 days, 3 days = max observed actual}  (12 scenarios)
             + scenario 13 "ERP current": the ReorderLevel / TargetStockLevel
               stored in WWI, declared lead time (baseline to beat).
             + scenarios 14-17 "fill-rate targeted" (actual 3 d lead time):
               k chosen so that expected units short per order cycle
               = (1 - target fill rate) x Q, using the standard normal loss
               function G(k) = phi(k) - k (1 - Phi(k));  Q = max(7 x mu_d, pack size).
               SS = max(0, k x sigma_LT). (CSL-based z over-delivers on fill rate.)

   For month m (parameters use only data before m):
     mu_d     = SEAS forecast for m / days in m                 (units per day)
     sigma_d  = stdev of daily demand over the 365 days before m (zeros included)
     e_rel    = RMSE of SEAS monthly errors over the 12 months before m
                / mean actual monthly demand over the same months
     sigma_LT = sqrt( LT * sigma_d^2 + (LT * mu_d * e_rel)^2 )
                (day-to-day noise  +  uncertainty of the forecast level)
     SS       = z * sigma_LT
     ROP      = mu_d * LT + SS
     S        = ROP + mu_d * 7            (order-up-to: ~1 week of cycle stock)
   Orders are later rounded up to whole outers (QuantityPerOuter).
   ===================================================================== */
USE WWI_Analytics;
GO
CREATE OR ALTER PROCEDURE gold.usp_build_policy_parameters
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t DATETIME2(0) = SYSDATETIME(), @n INT;

    DROP TABLE IF EXISTS gold.dim_policy_scenario;
    SELECT ISNULL(CAST(ROW_NUMBER() OVER (ORDER BY lt.ord, sl.sl) AS INT), 0) AS scenario_id,
           CAST(NULLIF(sl.sl, -1) AS DECIMAL(5,3)) AS service_level,   -- NULLIF => nullable (scenario 13 has none)
           CAST(NULLIF(sl.z, -1) AS DECIMAL(6,4)) AS z, lt.lt_scenario,
           CONCAT(lt.lt_scenario, ' LT | SL ', FORMAT(sl.sl, 'P1')) AS scenario_name,
           CAST('CSL' AS VARCHAR(10)) AS target_type
    INTO gold.dim_policy_scenario
    FROM (VALUES (0.90, 1.2816), (0.95, 1.6449), (0.975, 1.9600), (0.99, 2.3263)) sl(sl, z)
    CROSS JOIN (VALUES (1, 'declared'), (2, 'mid 7d'), (3, 'actual 3d')) lt(ord, lt_scenario);
    INSERT INTO gold.dim_policy_scenario (scenario_id, service_level, z, lt_scenario, scenario_name, target_type)
    VALUES (13, NULL, NULL, 'declared', 'ERP current parameters', 'ERP'),
           (14, 0.950, NULL, 'actual 3d', 'actual 3d LT | FR 95.0%', 'FR'),
           (15, 0.975, NULL, 'actual 3d', 'actual 3d LT | FR 97.5%', 'FR'),
           (16, 0.990, NULL, 'actual 3d', 'actual 3d LT | FR 99.0%', 'FR'),
           (17, 0.995, NULL, 'actual 3d', 'actual 3d LT | FR 99.5%', 'FR');

    /* standard normal loss function lookup, k = -2.00 .. 4.00 (Abramowitz-Stegun approximation of Phi) */
    DROP TABLE IF EXISTS gold.normal_loss_table;
    WITH k AS (SELECT TOP (601) CAST((ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 201) / 100.0 AS FLOAT) AS k
               FROM sys.all_objects),
    p AS (SELECT k, EXP(-k * k / 2) / SQRT(2 * PI()) AS pdf, 1.0 / (1 + 0.2316419 * ABS(k)) AS t FROM k),
    c AS (SELECT k, pdf,
                 1 - pdf * (0.319381530 * t - 0.356563782 * POWER(t, 2) + 1.781477937 * POWER(t, 3)
                            - 1.821255978 * POWER(t, 4) + 1.330274429 * POWER(t, 5)) AS cdf_abs
          FROM p)
    SELECT k, pdf, CASE WHEN k >= 0 THEN cdf_abs ELSE 1 - cdf_abs END AS cdf,
           pdf - k * (1 - CASE WHEN k >= 0 THEN cdf_abs ELSE 1 - cdf_abs END) AS loss
    INTO gold.normal_loss_table
    FROM c;
    CREATE UNIQUE CLUSTERED INDEX UX_dim_policy_scenario ON gold.dim_policy_scenario (scenario_id);

    DROP TABLE IF EXISTS gold.policy_parameters;
    WITH months AS (
        SELECT DISTINCT month_start, days_in_month FROM gold.fact_demand_monthly
        WHERE month_start BETWEEN '2015-06-01' AND '2016-05-01'),
    stats AS (
        SELECT c.stock_item_id, m.month_start, m.days_in_month,
               fc.forecast_units / m.days_in_month AS mu_d,
               dd.sigma_d,
               err.rmse / NULLIF(err.mean_actual, 0) AS e_rel
        FROM gold.sku_classification c
        CROSS JOIN months m
        JOIN gold.fact_forecast fc
          ON fc.stock_item_id = c.stock_item_id AND fc.model = 'SEAS' AND fc.month_start = m.month_start
        CROSS APPLY (SELECT STDEV(CAST(d.demand_qty AS FLOAT)) AS sigma_d
                     FROM gold.fact_demand_daily d
                     WHERE d.stock_item_id = c.stock_item_id
                       AND d.[date] >= DATEADD(DAY, -365, m.month_start) AND d.[date] < m.month_start) dd
        CROSS APPLY (SELECT SQRT(AVG(SQUARE(e.error_units))) AS rmse, AVG(CAST(e.actual_units AS FLOAT)) AS mean_actual
                     FROM gold.fact_forecast e
                     WHERE e.stock_item_id = c.stock_item_id AND e.model = 'SEAS'
                       AND e.month_start >= DATEADD(MONTH, -12, m.month_start) AND e.month_start < m.month_start) err
        WHERE c.is_new_product = 0)
    SELECT  sc.scenario_id, s.stock_item_id, s.month_start,
            s.mu_d, s.sigma_d, s.e_rel,
            lt.lt_days,
            i.quantity_per_outer,
            p.sigma_lt,
            CASE WHEN sc.scenario_id = 13 THEN 0 ELSE sc.z * p.sigma_lt END AS safety_stock,
            CASE WHEN sc.scenario_id = 13 THEN i.erp_reorder_level
                 ELSE s.mu_d * lt.lt_days + sc.z * p.sigma_lt END AS reorder_point,
            CASE WHEN sc.scenario_id = 13 THEN i.erp_target_stock_level
                 ELSE s.mu_d * lt.lt_days + sc.z * p.sigma_lt + s.mu_d * 7 END AS order_up_to
    INTO gold.policy_parameters
    FROM stats s
    JOIN gold.dim_stock_item i ON i.stock_item_id = s.stock_item_id
    CROSS JOIN (SELECT * FROM gold.dim_policy_scenario WHERE target_type <> 'FR') sc
    CROSS APPLY (SELECT CASE sc.lt_scenario WHEN 'declared' THEN i.declared_lead_time_days
                                            WHEN 'mid 7d'   THEN 7 ELSE 3 END AS lt_days) lt
    CROSS APPLY (SELECT SQRT(lt.lt_days * SQUARE(s.sigma_d) + SQUARE(lt.lt_days * s.mu_d * s.e_rel)) AS sigma_lt) p;
    SET @n = @@ROWCOUNT;

    /* fill-rate-targeted scenarios: reuse mu_d / sigma_lt of the CSL scenario with the same lead time (scenario 10 = actual 3d) */
    INSERT INTO gold.policy_parameters
        (scenario_id, stock_item_id, month_start, mu_d, sigma_d, e_rel, lt_days, quantity_per_outer,
         sigma_lt, safety_stock, reorder_point, order_up_to)
    SELECT sc.scenario_id, b.stock_item_id, b.month_start, b.mu_d, b.sigma_d, b.e_rel, b.lt_days, b.quantity_per_outer,
           b.sigma_lt, ss.safety_stock,
           b.mu_d * b.lt_days + ss.safety_stock,
           b.mu_d * b.lt_days + ss.safety_stock + b.mu_d * 7
    FROM gold.policy_parameters b
    CROSS JOIN (SELECT scenario_id, service_level FROM gold.dim_policy_scenario WHERE target_type = 'FR') sc
    CROSS APPLY (SELECT CASE WHEN b.mu_d * 7 > b.quantity_per_outer THEN b.mu_d * 7 ELSE b.quantity_per_outer END AS q) q
    CROSS APPLY (SELECT MIN(nl.k) AS k FROM gold.normal_loss_table nl
                 WHERE nl.loss <= (1 - sc.service_level) * q.q / NULLIF(b.sigma_lt, 0)) kk
    CROSS APPLY (SELECT CASE WHEN ISNULL(kk.k, 4) * b.sigma_lt > 0 THEN ISNULL(kk.k, 4) * b.sigma_lt ELSE 0 END AS safety_stock) ss
    WHERE b.scenario_id = 10;
    SET @n = @n + @@ROWCOUNT;

    CREATE UNIQUE CLUSTERED INDEX UX_policy_parameters ON gold.policy_parameters (scenario_id, stock_item_id, month_start);
    EXEC silver.usp_log 'gold.policy_parameters', @n, @t;

    SELECT sc.scenario_id, sc.scenario_name, COUNT(*) AS rows_,
           CAST(AVG(p.safety_stock) AS DECIMAL(12,1)) AS avg_ss_units,
           CAST(AVG(p.reorder_point) AS DECIMAL(12,1)) AS avg_rop_units,
           CAST(SUM(p.safety_stock * i.last_cost_price) / 12 AS DECIMAL(14,0)) AS avg_monthly_ss_value
    FROM gold.policy_parameters p
    JOIN gold.dim_policy_scenario sc ON sc.scenario_id = p.scenario_id
    JOIN gold.dim_stock_item i ON i.stock_item_id = p.stock_item_id
    GROUP BY sc.scenario_id, sc.scenario_name ORDER BY sc.scenario_id;
END
GO
