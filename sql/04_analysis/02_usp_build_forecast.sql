/* =====================================================================
   02_usp_build_forecast.sql
   gold.usp_build_forecast : rolling one-step-ahead monthly forecasts per SKU,
   backtest accuracy, and per-SKU model selection.  (Business question Q2)

   Models (forecast for month m is made with data up to m-1 only):
     MA3    : average of the last 3 months
     SNAIVE : same month last year
     SEAS   : deseasonalised 12-month level x seasonal index of month m
              x trend factor (last 12 / previous 12 months) ^ (6.5 / 12)
              Seasonal index = company-level, from complete years 2013-2014
              (calibration data only).
   Selection : per SKU, the model with the lowest WAPE over the calibration
               backtest window 2014-01 .. 2015-05 is the "selected" model.
   Test      : accuracy of the selected model on 2015-06 .. 2016-05 is
               out-of-sample (selection never saw those months).
   Metrics   : WAPE = sum|F-A| / sum A ; bias = sum(F-A) / sum A ;
               MAPE (months with A > 0) kept for reference.
   New products (no calibration demand) are excluded.
   ===================================================================== */
USE WWI_Analytics;
GO
CREATE OR ALTER PROCEDURE gold.usp_build_forecast
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t DATETIME2(0) = SYSDATETIME(), @n INT;

    /* ---------- seasonal index (company level, 2013-2014) ---------- */
    DROP TABLE IF EXISTS gold.seasonal_index;
    WITH m AS (
        SELECT month_start, YEAR(month_start) AS y, MONTH(month_start) AS mo, SUM(demand_units) AS units
        FROM gold.fact_demand_monthly
        WHERE month_start >= '2013-01-01' AND month_start < '2015-01-01'
        GROUP BY month_start)
    SELECT ISNULL(mo, 0) AS [month], AVG(units * 1.0 / yr_avg) AS seasonal_index
    INTO gold.seasonal_index
    FROM (SELECT *, AVG(units * 1.0) OVER (PARTITION BY y) AS yr_avg FROM m) x
    GROUP BY mo;

    /* ---------- forecasts ---------- */
    DROP TABLE IF EXISTS gold.fact_forecast;
    WITH base AS (
        SELECT f.stock_item_id, f.month_start, f.model_period, f.demand_units,
               f.demand_units / si.seasonal_index AS deseason_units,
               si.seasonal_index,
               ROW_NUMBER() OVER (PARTITION BY f.stock_item_id ORDER BY f.month_start) AS rn
        FROM gold.fact_demand_monthly f
        JOIN gold.seasonal_index si ON si.[month] = MONTH(f.month_start)
        JOIN gold.sku_classification c ON c.stock_item_id = f.stock_item_id AND c.is_new_product = 0),
    w AS (
        SELECT *,
               AVG(CAST(demand_units AS FLOAT)) OVER (PARTITION BY stock_item_id ORDER BY month_start ROWS BETWEEN 3 PRECEDING AND 1 PRECEDING) AS ma3,
               LAG(demand_units, 12) OVER (PARTITION BY stock_item_id ORDER BY month_start) AS snaive,
               AVG(deseason_units) OVER (PARTITION BY stock_item_id ORDER BY month_start ROWS BETWEEN 12 PRECEDING AND 1 PRECEDING) AS level12,
               SUM(CAST(demand_units AS FLOAT)) OVER (PARTITION BY stock_item_id ORDER BY month_start ROWS BETWEEN 12 PRECEDING AND 1 PRECEDING) AS sum_last12,
               SUM(CAST(demand_units AS FLOAT)) OVER (PARTITION BY stock_item_id ORDER BY month_start ROWS BETWEEN 24 PRECEDING AND 13 PRECEDING) AS sum_prev12
        FROM base),
    fc AS (
        SELECT stock_item_id, month_start, model_period, demand_units, rn,
               ma3, CAST(snaive AS FLOAT) AS snaive,
               level12 * seasonal_index *
                   POWER(CASE WHEN rn > 24 AND sum_prev12 > 0 THEN sum_last12 / sum_prev12 ELSE 1.0 END, 6.5 / 12.0) AS seas
        FROM w
        WHERE rn > 12)                     -- need 12 months of history
    SELECT  stock_item_id, month_start, model_period, model, forecast_units,
            demand_units AS actual_units,
            forecast_units - demand_units AS error_units,
            ABS(forecast_units - demand_units) AS abs_error_units
    INTO gold.fact_forecast
    FROM fc
    CROSS APPLY (VALUES ('MA3', ma3), ('SNAIVE', snaive), ('SEAS', seas)) v(model, forecast_units);
    SET @n = @@ROWCOUNT;
    CREATE UNIQUE CLUSTERED INDEX UX_fact_forecast ON gold.fact_forecast (stock_item_id, model, month_start);
    EXEC silver.usp_log 'gold.fact_forecast', @n, @t;

    /* ---------- per-SKU model selection on calibration backtest ---------- */
    SET @t = SYSDATETIME();
    DROP TABLE IF EXISTS gold.forecast_model_selection;
    WITH acc AS (
        SELECT stock_item_id, model,
               SUM(abs_error_units) / NULLIF(SUM(CAST(actual_units AS FLOAT)), 0) AS wape_calib
        FROM gold.fact_forecast
        WHERE month_start BETWEEN '2014-01-01' AND '2015-05-01'
        GROUP BY stock_item_id, model)
    SELECT stock_item_id, model AS selected_model, wape_calib
    INTO gold.forecast_model_selection
    FROM (SELECT *, ROW_NUMBER() OVER (PARTITION BY stock_item_id ORDER BY wape_calib, model) AS r FROM acc) x
    WHERE r = 1;
    SET @n = @@ROWCOUNT;
    EXEC silver.usp_log 'gold.forecast_model_selection', @n, @t;

    /* ---------- accuracy summary: each model + selected, calibration vs test ---------- */
    SET @t = SYSDATETIME();
    DROP TABLE IF EXISTS gold.forecast_accuracy;
    WITH f AS (
        SELECT ff.*, CASE WHEN ff.month_start >= '2015-06-01' THEN 'test' ELSE 'calibration' END AS window_,
               CASE WHEN s.selected_model = ff.model THEN 1 ELSE 0 END AS is_selected
        FROM gold.fact_forecast ff
        JOIN gold.forecast_model_selection s ON s.stock_item_id = ff.stock_item_id
        WHERE ff.month_start >= '2014-01-01')
    SELECT window_, model,
           SUM(abs_error_units) / SUM(CAST(actual_units AS FLOAT)) AS wape,
           SUM(error_units)     / SUM(CAST(actual_units AS FLOAT)) AS bias,
           AVG(CASE WHEN actual_units > 0 THEN abs_error_units / actual_units END) AS mape,
           COUNT(*) AS sku_months
    INTO gold.forecast_accuracy
    FROM (SELECT window_, model, abs_error_units, error_units, actual_units FROM f
          UNION ALL
          SELECT window_, 'SELECTED', abs_error_units, error_units, actual_units FROM f WHERE is_selected = 1) u
    GROUP BY window_, model;
    SET @n = @@ROWCOUNT;
    EXEC silver.usp_log 'gold.forecast_accuracy', @n, @t;

    SELECT * FROM gold.seasonal_index ORDER BY [month];
    SELECT selected_model, COUNT(*) AS skus FROM gold.forecast_model_selection GROUP BY selected_model;
    SELECT window_, model, CAST(wape AS DECIMAL(6,4)) wape, CAST(bias AS DECIMAL(6,4)) bias,
           CAST(mape AS DECIMAL(6,4)) mape, sku_months
    FROM gold.forecast_accuracy ORDER BY window_, wape;
END
GO
