/* =====================================================================
   01_usp_load_bronze.sql
   bronze.usp_load_bronze  @load_type = 'full' | 'incremental', @only_table = NULL | bronze table name
   For each active row in etl.bronze_config:
     1. builds the column list from source metadata (skips geography/varbinary)
     2. creates the bronze table on first run (SELECT ... INTO ... WHERE 1=0)
     3. full        : TRUNCATE + INSERT
        incremental : DELETE changed keys + INSERT rows with watermark > last watermark
                      (falls back to full when table has no watermark column)
     4. stores new MAX(watermark) in etl.watermark, logs every table in etl.load_log
   Limitation: hard deletes in the source are not detected by incremental mode
   (WWI never hard-deletes business rows; run 'full' periodically if needed).
   ===================================================================== */
USE WWI_Analytics;
GO
CREATE OR ALTER PROCEDURE bronze.usp_load_bronze
    @load_type  VARCHAR(12) = 'incremental',
    @only_table SYSNAME     = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @src_schema SYSNAME, @src_table SYSNAME, @bt SYSNAME, @pk SYSNAME, @wm SYSNAME,
            @src_full NVARCHAR(400), @tgt NVARCHAR(400), @cols NVARCHAR(MAX), @sql NVARCHAR(MAX),
            @mode VARCHAR(12), @log_id INT, @rows INT, @last DATETIME2(7), @newmax DATETIME2(7),
            @first_log INT = (SELECT ISNULL(MAX(log_id), 0) + 1 FROM etl.load_log);

    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT source_schema, source_table, bronze_table, pk_col, watermark_col
        FROM etl.bronze_config
        WHERE is_active = 1 AND (@only_table IS NULL OR bronze_table = @only_table)
        ORDER BY source_schema, source_table;

    OPEN cur;
    FETCH NEXT FROM cur INTO @src_schema, @src_table, @bt, @pk, @wm;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @src_full = N'WideWorldImporters.' + QUOTENAME(@src_schema) + N'.' + QUOTENAME(@src_table);
        SET @tgt      = N'bronze.' + QUOTENAME(@bt);
        SET @rows = NULL; SET @newmax = NULL;

        SELECT @cols = STRING_AGG(CAST(QUOTENAME(c.name) AS NVARCHAR(MAX)), N', ') WITHIN GROUP (ORDER BY c.column_id)
        FROM WideWorldImporters.sys.columns c
        JOIN WideWorldImporters.sys.types t ON t.user_type_id = c.user_type_id
        WHERE c.object_id = OBJECT_ID(@src_full)
          AND t.name NOT IN ('geography', 'geometry', 'varbinary', 'hierarchyid');

        SET @mode = CASE WHEN @load_type = 'full' OR @wm IS NULL OR @pk IS NULL OR OBJECT_ID(@tgt) IS NULL
                         THEN 'full' ELSE 'incremental' END;

        INSERT INTO etl.load_log (layer, object_name, load_type) VALUES ('bronze', @bt, @mode);
        SET @log_id = SCOPE_IDENTITY();

        BEGIN TRY
            IF OBJECT_ID(@tgt) IS NULL
            BEGIN
                SET @sql = N'SELECT ' + @cols + N', CAST(SYSDATETIME() AS DATETIME2(0)) AS dwh_load_ts INTO '
                         + @tgt + N' FROM ' + @src_full + N' WHERE 1 = 0;';
                EXEC sp_executesql @sql;
            END

            IF @mode = 'full'
            BEGIN
                SET @sql = N'TRUNCATE TABLE ' + @tgt + N'; '
                         + N'INSERT INTO ' + @tgt + N' (' + @cols + N', dwh_load_ts) '
                         + N'SELECT ' + @cols + N', SYSDATETIME() FROM ' + @src_full + N'; SET @r = @@ROWCOUNT;';
                EXEC sp_executesql @sql, N'@r INT OUTPUT', @r = @rows OUTPUT;
            END
            ELSE
            BEGIN
                SELECT @last = last_loaded_at FROM etl.watermark WHERE source_table = @bt;
                SET @last = ISNULL(@last, '1900-01-01');
                SET @sql = N'DELETE b FROM ' + @tgt + N' b WHERE EXISTS (SELECT 1 FROM ' + @src_full + N' s '
                         + N'WHERE s.' + QUOTENAME(@pk) + N' = b.' + QUOTENAME(@pk) + N' AND s.' + QUOTENAME(@wm) + N' > @last); '
                         + N'INSERT INTO ' + @tgt + N' (' + @cols + N', dwh_load_ts) '
                         + N'SELECT ' + @cols + N', SYSDATETIME() FROM ' + @src_full
                         + N' WHERE ' + QUOTENAME(@wm) + N' > @last; SET @r = @@ROWCOUNT;';
                EXEC sp_executesql @sql, N'@last DATETIME2(7), @r INT OUTPUT', @last = @last, @r = @rows OUTPUT;
            END

            IF @wm IS NOT NULL
            BEGIN
                SET @sql = N'SELECT @m = MAX(' + QUOTENAME(@wm) + N') FROM ' + @tgt + N';';
                EXEC sp_executesql @sql, N'@m DATETIME2(7) OUTPUT', @m = @newmax OUTPUT;
                MERGE etl.watermark AS t
                USING (SELECT @bt AS source_table, ISNULL(@newmax, '1900-01-01') AS m) AS s
                   ON t.source_table = s.source_table
                WHEN MATCHED THEN UPDATE SET last_loaded_at = s.m
                WHEN NOT MATCHED THEN INSERT (source_table, last_loaded_at) VALUES (s.source_table, s.m);
            END

            UPDATE etl.load_log SET rows_affected = @rows, finished_at = SYSDATETIME(), status = 'success'
            WHERE log_id = @log_id;
        END TRY
        BEGIN CATCH
            UPDATE etl.load_log SET finished_at = SYSDATETIME(), status = 'failed', error_message = ERROR_MESSAGE()
            WHERE log_id = @log_id;
        END CATCH

        FETCH NEXT FROM cur INTO @src_schema, @src_table, @bt, @pk, @wm;
    END
    CLOSE cur; DEALLOCATE cur;

    SELECT log_id, object_name, load_type, rows_affected, status, error_message,
           DATEDIFF(MILLISECOND, started_at, finished_at) AS ms
    FROM etl.load_log WHERE log_id >= @first_log ORDER BY log_id;
END
GO
