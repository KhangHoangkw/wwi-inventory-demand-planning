/* =====================================================================
   03_create_etl_user.sql
   Least-privilege SQL login used to build and run the pipeline.
   - WideWorldImporters : READ ONLY (source system, never modified)
   - WWI_Analytics      : create/alter objects ONLY in bronze/silver/gold/etl,
                          read/write data there, take backups
   - No server-level rights: cannot touch master, other DBs, logins, or DROP DATABASE
   Run as your Windows admin account in SSMS.
   >>> Replace the password before running. Do NOT commit the real password. <<<
   ===================================================================== */
USE master;
GO
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = 'wwi_etl')
    CREATE LOGIN wwi_etl
    WITH PASSWORD = N'<<SET_A_STRONG_PASSWORD>>',
         DEFAULT_DATABASE = WWI_Analytics,
         CHECK_POLICY = ON;
GO

/* ---------- Source DB: read only ---------- */
USE WideWorldImporters;
GO
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'wwi_etl')
    CREATE USER wwi_etl FOR LOGIN wwi_etl;
ALTER ROLE db_datareader ADD MEMBER wwi_etl;     -- SELECT on all tables/views
GRANT VIEW DEFINITION TO wwi_etl;                -- read table/proc definitions
DENY  INSERT, UPDATE, DELETE, EXECUTE TO wwi_etl; -- belt and braces
GO

/* ---------- Analytics DB: build inside our 4 schemas only ---------- */
USE WWI_Analytics;
GO
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'wwi_etl')
    CREATE USER wwi_etl FOR LOGIN wwi_etl;

GRANT CREATE TABLE, CREATE VIEW, CREATE PROCEDURE, CREATE FUNCTION TO wwi_etl;
GRANT SHOWPLAN, VIEW DEFINITION TO wwi_etl;

GRANT ALTER, SELECT, INSERT, UPDATE, DELETE, EXECUTE, REFERENCES ON SCHEMA::bronze TO wwi_etl;
GRANT ALTER, SELECT, INSERT, UPDATE, DELETE, EXECUTE, REFERENCES ON SCHEMA::silver TO wwi_etl;
GRANT ALTER, SELECT, INSERT, UPDATE, DELETE, EXECUTE, REFERENCES ON SCHEMA::gold   TO wwi_etl;
GRANT ALTER, SELECT, INSERT, UPDATE, DELETE, EXECUTE, REFERENCES ON SCHEMA::etl    TO wwi_etl;

ALTER ROLE db_backupoperator ADD MEMBER wwi_etl;  -- allows a backup before destructive changes
GO

/* ---------- Verify ---------- */
EXECUTE AS LOGIN = 'wwi_etl';
SELECT SUSER_NAME() AS login_name,
       HAS_PERMS_BY_NAME('WideWorldImporters', 'DATABASE', 'SELECT') AS wwi_select,   -- expect 1
       HAS_PERMS_BY_NAME('WideWorldImporters.Sales.Orders', 'OBJECT', 'DELETE') AS wwi_delete, -- expect 0
       HAS_PERMS_BY_NAME('WWI_Analytics', 'DATABASE', 'CREATE TABLE') AS wa_create,   -- expect 1
       IS_SRVROLEMEMBER('sysadmin') AS is_sysadmin;                                   -- expect 0
REVERT;
GO
