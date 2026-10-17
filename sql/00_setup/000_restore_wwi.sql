/* =====================================================================
   000_restore_wwi.sql  -- restore Microsoft's WideWorldImporters sample
   1) Copy WideWorldImporters-Full.bak into the SQL Server Backup folder:
      C:\Program Files\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQL\Backup\
      (SQL Server's service account can always read this folder)
   2) Run STEP A, check the logical names, then run STEP B.
   ===================================================================== */
USE master;
GO
-- STEP A: list logical file names inside the backup
RESTORE FILELISTONLY
FROM DISK = N'C:\Program Files\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQL\Backup\WideWorldImporters-Full.bak';
GO
-- STEP B: restore (logical names below are the usual ones; fix them if STEP A shows different)
RESTORE DATABASE WideWorldImporters
FROM DISK = N'C:\Program Files\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQL\Backup\WideWorldImporters-Full.bak'
WITH
  MOVE N'WWI_Primary'          TO N'C:\Program Files\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQL\DATA\WideWorldImporters.mdf',
  MOVE N'WWI_UserData'         TO N'C:\Program Files\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQL\DATA\WideWorldImporters_UserData.ndf',
  MOVE N'WWI_Log'              TO N'C:\Program Files\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQL\DATA\WideWorldImporters.ldf',
  MOVE N'WWI_InMemory_Data_1'  TO N'C:\Program Files\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQL\DATA\WideWorldImporters_InMemory_Data_1',
  RECOVERY, STATS = 10;
GO
-- STEP C: quick check
SELECT name, state_desc, compatibility_level FROM sys.databases WHERE name = 'WideWorldImporters';
