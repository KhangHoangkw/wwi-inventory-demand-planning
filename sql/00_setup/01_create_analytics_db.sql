/* =====================================================================
   01_create_analytics_db.sql
   Creates the analytics database and the medallion schemas.
   Source DB  : WideWorldImporters (restored from Microsoft sample .bak)
   Target DB  : WWI_Analytics
   ===================================================================== */
USE master;
GO
IF DB_ID('WWI_Analytics') IS NULL
    CREATE DATABASE WWI_Analytics;
GO
USE WWI_Analytics;
GO
IF SCHEMA_ID('bronze') IS NULL EXEC('CREATE SCHEMA bronze');   -- raw copies of source tables
IF SCHEMA_ID('silver') IS NULL EXEC('CREATE SCHEMA silver');   -- cleaned, conformed
IF SCHEMA_ID('gold')   IS NULL EXEC('CREATE SCHEMA gold');     -- star schema + KPI views
IF SCHEMA_ID('etl')    IS NULL EXEC('CREATE SCHEMA etl');      -- load log, watermarks, DQ results
GO

/* ETL run log: one row per procedure run */
IF OBJECT_ID('etl.load_log') IS NULL
CREATE TABLE etl.load_log (
    log_id        INT IDENTITY(1,1) PRIMARY KEY,
    layer         VARCHAR(10)   NOT NULL,      -- bronze / silver / gold
    object_name   SYSNAME       NOT NULL,
    load_type     VARCHAR(12)   NOT NULL,      -- full / incremental
    rows_affected INT           NULL,
    started_at    DATETIME2(0)  NOT NULL DEFAULT SYSDATETIME(),
    finished_at   DATETIME2(0)  NULL,
    status        VARCHAR(10)   NOT NULL DEFAULT 'running',   -- running / success / failed
    error_message NVARCHAR(4000) NULL
);

/* Watermarks for incremental loads (by LastEditedWhen / ValidFrom) */
IF OBJECT_ID('etl.watermark') IS NULL
CREATE TABLE etl.watermark (
    source_table   SYSNAME      PRIMARY KEY,
    last_loaded_at DATETIME2(7) NOT NULL DEFAULT '1900-01-01'
);

/* Data quality check results */
IF OBJECT_ID('etl.dq_result') IS NULL
CREATE TABLE etl.dq_result (
    dq_id        INT IDENTITY(1,1) PRIMARY KEY,
    check_name   VARCHAR(200) NOT NULL,
    layer        VARCHAR(10)  NOT NULL,
    failed_rows  INT          NOT NULL,
    severity     VARCHAR(10)  NOT NULL,        -- error / warning
    checked_at   DATETIME2(0) NOT NULL DEFAULT SYSDATETIME()
);
GO
