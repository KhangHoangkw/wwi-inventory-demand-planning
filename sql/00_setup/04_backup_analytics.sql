/* =====================================================================
   04_backup_analytics.sql
   Timestamped full backup of WWI_Analytics. Run BEFORE any DROP / DELETE /
   UPDATE / TRUNCATE or before re-running a whole layer.
   Restore example (run as admin):
     RESTORE DATABASE WWI_Analytics FROM DISK = N'...\WWI_Analytics_YYYYMMDD_HHMM.bak' WITH REPLACE;
   ===================================================================== */
DECLARE @file NVARCHAR(400) =
    N'C:\Program Files\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQL\Backup\WWI_Analytics_'
    + FORMAT(SYSDATETIME(), 'yyyyMMdd_HHmm') + N'.bak';

BACKUP DATABASE WWI_Analytics
TO DISK = @file
WITH COPY_ONLY, COMPRESSION, CHECKSUM, INIT, STATS = 25;

SELECT @file AS backup_file;
