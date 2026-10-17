/* =====================================================================
   05_grant_customer_rls_access.sql   -- RUN AS ADMIN (your Windows login) in SSMS
   Why: WideWorldImporters has Row-Level Security on Sales.Customers
        (policy FilterCustomersBySalesTerritoryRole). A user only sees customers
        whose delivery city belongs to a "<Territory> Sales" role the user is in
        (or db_owner). wwi_etl currently sees 0 of 663 customers.
   Fix (least privilege): add wwi_etl to the 9 territory roles instead of db_owner.
        These roles are used by the RLS predicate; they do not grant write rights.
   ===================================================================== */
USE WideWorldImporters;
GO
DECLARE @r SYSNAME, @sql NVARCHAR(400);
DECLARE c CURSOR LOCAL FOR
    SELECT name FROM sys.database_principals WHERE type = 'R' AND name LIKE N'% Sales';
OPEN c; FETCH NEXT FROM c INTO @r;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'ALTER ROLE ' + QUOTENAME(@r) + N' ADD MEMBER wwi_etl;';
    EXEC (@sql);
    FETCH NEXT FROM c INTO @r;
END
CLOSE c; DEALLOCATE c;
GO
-- Check: should return 663
EXECUTE AS USER = 'wwi_etl';
SELECT COUNT(*) AS customers_visible FROM Sales.Customers;
REVERT;
GO
