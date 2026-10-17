/* =====================================================================
   01_usp_build_demand_base.sql
   gold.usp_build_demand_base
     - gold.fact_demand_monthly : SKU x month demand (units, value, lines)
     - gold.sku_classification  : ABC (revenue share) x XYZ (demand variability)
       computed on the CALIBRATION window only (2013-01 .. 2015-05) so the
       classification used by the policy has no look-ahead into the test year.
   Business question: which SKUs drive revenue and how predictable are they? (Q1)
   Rules: A = top 80% of cumulative revenue, B = next 15%, C = last 5%
          X: CV < 0.5 (stable), Y: 0.5-1.0 (variable), Z: >= 1.0 (erratic)
          XYZ uses the WEEKLY CV (stdev / mean of weekly units, zero weeks included).
          Monthly CV is also stored, but every selling SKU has monthly CV ~0.25
          (all "X"), so it does not discriminate.
          is_new_product = 1 when the SKU has no demand in the calibration window
          (8 chocolate SKUs launched Jan 2016): no history -> excluded from the
          statistical policy, flagged for judgmental planning.
   ===================================================================== */
USE WWI_Analytics;
GO
CREATE OR ALTER PROCEDURE gold.usp_build_demand_base
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t DATETIME2(0) = SYSDATETIME(), @n INT;

    DROP TABLE IF EXISTS gold.fact_demand_monthly;
    SELECT  s.stock_item_id,
            m.month_start,
            ISNULL(CAST(CONVERT(CHAR(8), m.month_start, 112) AS INT), 0) AS month_key,
            m.days_in_month,
            m.model_period,
            ISNULL(x.units, 0)  AS demand_units,
            ISNULL(x.value, 0)  AS demand_value,
            ISNULL(x.lines, 0)  AS order_lines
    INTO gold.fact_demand_monthly
    FROM gold.dim_stock_item s
    CROSS JOIN (SELECT month_start, COUNT(*) AS days_in_month, MIN(model_period) AS model_period
                FROM gold.dim_date WHERE [date] <= '2016-05-31' GROUP BY month_start) m
    LEFT JOIN (SELECT stock_item_id, DATEFROMPARTS(YEAR(order_date), MONTH(order_date), 1) AS month_start,
                      SUM(quantity) AS units, SUM(line_value_excl_tax) AS value, COUNT(*) AS lines
               FROM gold.fact_order_line
               GROUP BY stock_item_id, DATEFROMPARTS(YEAR(order_date), MONTH(order_date), 1)) x
           ON x.stock_item_id = s.stock_item_id AND x.month_start = m.month_start;
    SET @n = @@ROWCOUNT;
    CREATE UNIQUE CLUSTERED INDEX UX_fact_demand_monthly ON gold.fact_demand_monthly (stock_item_id, month_start);
    EXEC silver.usp_log 'gold.fact_demand_monthly', @n, @t;

    SET @t = SYSDATETIME();
    DROP TABLE IF EXISTS gold.sku_classification;
    WITH c AS (
        SELECT stock_item_id,
               SUM(demand_value)               AS calib_revenue,
               SUM(demand_units)               AS calib_units,
               AVG(CAST(demand_units AS FLOAT)) AS mean_monthly_units,
               STDEV(CAST(demand_units AS FLOAT)) AS sd_monthly_units,
               SUM(CASE WHEN demand_units = 0 THEN 1 ELSE 0 END) AS zero_months,
               COUNT(*) AS months
        FROM gold.fact_demand_monthly
        WHERE model_period = 'calibration'
        GROUP BY stock_item_id),
    r AS (
        SELECT *,
               SUM(calib_revenue) OVER (ORDER BY calib_revenue DESC, stock_item_id ROWS UNBOUNDED PRECEDING)
                 / NULLIF(SUM(calib_revenue) OVER (), 0) AS cum_revenue_share,
               sd_monthly_units / NULLIF(mean_monthly_units, 0) AS cv
        FROM c)
    SELECT  stock_item_id, calib_revenue, calib_units, mean_monthly_units, sd_monthly_units,
            zero_months, months, cum_revenue_share, cv,
            CASE WHEN cum_revenue_share <= 0.80 THEN 'A' WHEN cum_revenue_share <= 0.95 THEN 'B' ELSE 'C' END AS abc_class,
            CASE WHEN cv < 0.5 THEN 'X' WHEN cv < 1.0 THEN 'Y' ELSE 'Z' END AS xyz_class
    INTO gold.sku_classification
    FROM r;
    SET @n = @@ROWCOUNT;
    CREATE UNIQUE CLUSTERED INDEX UX_sku_classification ON gold.sku_classification (stock_item_id);

    ALTER TABLE gold.sku_classification ADD weekly_cv FLOAT NULL, is_new_product BIT NULL;
    EXEC sp_executesql N'
    WITH w AS (
        SELECT d.stock_item_id, dd.week_start_monday, SUM(d.demand_qty) AS q
        FROM gold.fact_demand_daily d
        JOIN gold.dim_date dd ON dd.date_key = d.date_key
        WHERE dd.week_start_monday >= ''2013-01-07'' AND dd.week_start_monday <= ''2015-05-25''
        GROUP BY d.stock_item_id, dd.week_start_monday),
    cv AS (
        SELECT stock_item_id, STDEV(CAST(q AS FLOAT)) / NULLIF(AVG(CAST(q AS FLOAT)), 0) AS weekly_cv
        FROM w GROUP BY stock_item_id)
    UPDATE c
       SET weekly_cv      = cv.weekly_cv,
           is_new_product = CASE WHEN c.calib_units = 0 THEN 1 ELSE 0 END,
           xyz_class      = CASE WHEN c.calib_units = 0 THEN ''N''
                                 WHEN cv.weekly_cv < 0.5 THEN ''X''
                                 WHEN cv.weekly_cv < 1.0 THEN ''Y'' ELSE ''Z'' END,
           abc_class      = CASE WHEN c.calib_units = 0 THEN ''N'' ELSE c.abc_class END
    FROM gold.sku_classification c
    JOIN cv ON cv.stock_item_id = c.stock_item_id;';
    EXEC silver.usp_log 'gold.sku_classification', @n, @t;

    EXEC sp_executesql N'
    SELECT abc_class, xyz_class, COUNT(*) AS skus,
           CAST(SUM(calib_revenue) / SUM(SUM(calib_revenue)) OVER () AS DECIMAL(6,4)) AS revenue_share,
           CAST(AVG(cv) AS DECIMAL(6,3)) AS avg_monthly_cv, CAST(AVG(weekly_cv) AS DECIMAL(6,3)) AS avg_weekly_cv
    FROM gold.sku_classification
    GROUP BY abc_class, xyz_class
    ORDER BY abc_class, xyz_class;';
END
GO
