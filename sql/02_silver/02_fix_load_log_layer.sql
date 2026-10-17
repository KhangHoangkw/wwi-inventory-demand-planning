/* Fix: gold loads were logged with layer = 'silver'
   (gold.usp_load_gold reuses silver.usp_log, which hard-coded the layer).
   1) silver.usp_log now derives the layer from the object name (see 01_usp_load_silver.sql)
   2) one-off correction of the rows already logged. Backup taken before this UPDATE. */
CREATE OR ALTER PROCEDURE silver.usp_log
    @object SYSNAME, @rows INT, @started DATETIME2(0)
AS
    INSERT INTO etl.load_log (layer, object_name, load_type, rows_affected, started_at, finished_at, status)
    VALUES (CASE WHEN @object LIKE 'gold.%' THEN 'gold' ELSE 'silver' END,  -- gold loader reuses this logger
            @object, 'full', @rows, @started, SYSDATETIME(), 'success');
GO
UPDATE etl.load_log SET layer = 'gold' WHERE layer = 'silver' AND object_name LIKE 'gold.%';
