/* =====================================================================
   99_usp_run_pipeline.sql
   etl.usp_run_pipeline : one call that rebuilds everything end-to-end.
     bronze (incremental) -> silver -> data-quality checks -> gold star schema
     -> demand base + ABC/XYZ -> forecasts -> policy parameters -> simulation
     -> robustness checks
   Verified: a full re-run from source gives identical outputs
   (etl.vw_pipeline_fingerprint, before vs after).
   Run from SSMS (simulation of the full test year takes ~2-3 minutes).
   If your client enforces a short query timeout, run the steps separately
   and the simulation in 2-month chunks (@from / @to, @reset = 0 after the first).
   ===================================================================== */
USE WWI_Analytics;
GO
CREATE OR ALTER PROCEDURE etl.usp_run_pipeline
    @bronze_mode        VARCHAR(12) = 'incremental',
    @include_simulation BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    EXEC bronze.usp_load_bronze @load_type = @bronze_mode;
    EXEC silver.usp_load_silver;
    EXEC etl.usp_run_dq_checks;
    EXEC gold.usp_load_gold;
    EXEC gold.usp_build_demand_base;
    EXEC gold.usp_build_forecast;
    EXEC gold.usp_build_policy_parameters;
    IF @include_simulation = 1
    BEGIN
        EXEC gold.usp_simulate_policy @from = '2015-06-01', @to = '2016-05-31', @reset = 1;
        EXEC gold.usp_robustness_checks;           -- bootstrap CIs, month / SKU consistency
    END
END
GO
