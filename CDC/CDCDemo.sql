/*
    CDC Demo: The Shouldas, Couldas & Wouldas
    Databases: MyDatabase, YourDatabase, TheirDatabase

    Steps
      1. Enable CDC on each database
      2. Create a table with a primary key in each database
      3. Enable CDC on each table with @supports_net_changes = 1
      4. Verify
      5. Disable CDC on each database (cleanup, run separately)

    Run as sysadmin. SQL Agent must be running for the capture and cleanup jobs.
    If the databases are in an AG, run this on the primary.
*/

/* =========================================================
   1. Enable CDC on each database
   ========================================================= */

USE MyDatabase;
GO
IF (SELECT is_cdc_enabled FROM sys.databases WHERE name = DB_NAME()) = 0
    EXEC sys.sp_cdc_enable_db;
GO

USE YourDatabase;
GO
IF (SELECT is_cdc_enabled FROM sys.databases WHERE name = DB_NAME()) = 0
    EXEC sys.sp_cdc_enable_db;
GO

USE TheirDatabase;
GO
IF (SELECT is_cdc_enabled FROM sys.databases WHERE name = DB_NAME()) = 0
    EXEC sys.sp_cdc_enable_db;
GO

-- Confirm
SELECT name, is_cdc_enabled
FROM sys.databases
WHERE name IN (N'MyDatabase', N'YourDatabase', N'TheirDatabase');
GO


/* =========================================================
   2. Create a table with a primary key in each database
   ========================================================= */

USE MyDatabase;
GO
IF OBJECT_ID(N'dbo.Orders', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Orders
    (
        OrderID     INT IDENTITY(1,1) NOT NULL,
        CustomerID  INT               NOT NULL,
        OrderDate   DATETIME2(0)      NOT NULL CONSTRAINT DF_Orders_OrderDate DEFAULT (SYSDATETIME()),
        Status      VARCHAR(20)       NOT NULL CONSTRAINT DF_Orders_Status DEFAULT ('New'),
        CONSTRAINT PK_Orders PRIMARY KEY CLUSTERED (OrderID)
    );
END
GO

USE YourDatabase;
GO
IF OBJECT_ID(N'dbo.Customers', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Customers
    (
        CustomerID  INT IDENTITY(1,1) NOT NULL,
        FirstName   VARCHAR(50)       NOT NULL,
        LastName    VARCHAR(50)       NOT NULL,
        Email       VARCHAR(100)      NULL,
        CONSTRAINT PK_Customers PRIMARY KEY CLUSTERED (CustomerID)
    );
END
GO

USE TheirDatabase;
GO
IF OBJECT_ID(N'dbo.Products', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Products
    (
        ProductID   INT IDENTITY(1,1) NOT NULL,
        ProductName VARCHAR(100)      NOT NULL,
        Price       DECIMAL(10,2)     NOT NULL,
        IsActive    BIT               NOT NULL CONSTRAINT DF_Products_IsActive DEFAULT (1),
        CONSTRAINT PK_Products PRIMARY KEY CLUSTERED (ProductID)
    );
END
GO


/* =========================================================
   3. Enable CDC on each table with net changes
   ========================================================= */

USE MyDatabase;
GO
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE object_id = OBJECT_ID(N'dbo.Orders') AND is_tracked_by_cdc = 1)
    EXEC sys.sp_cdc_enable_table
        @source_schema        = N'dbo',
        @source_name          = N'Orders',
        @role_name            = NULL,
        @supports_net_changes = 1;
GO

USE YourDatabase;
GO
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE object_id = OBJECT_ID(N'dbo.Customers') AND is_tracked_by_cdc = 1)
    EXEC sys.sp_cdc_enable_table
        @source_schema        = N'dbo',
        @source_name          = N'Customers',
        @role_name            = NULL,
        @supports_net_changes = 1;
GO

USE TheirDatabase;
GO
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE object_id = OBJECT_ID(N'dbo.Products') AND is_tracked_by_cdc = 1)
    EXEC sys.sp_cdc_enable_table
        @source_schema        = N'dbo',
        @source_name          = N'Products',
        @role_name            = NULL,
        @supports_net_changes = 1;
GO


/* =========================================================
   4. Verify: capture instances and CDC jobs
   ========================================================= */

USE MyDatabase;
GO
EXEC sys.sp_cdc_help_change_data_capture;
EXEC sys.sp_cdc_help_jobs;
GO

USE YourDatabase;
GO
EXEC sys.sp_cdc_help_change_data_capture;
EXEC sys.sp_cdc_help_jobs;
GO

USE TheirDatabase;
GO
EXEC sys.sp_cdc_help_change_data_capture;
EXEC sys.sp_cdc_help_jobs;
GO

-- CDC jobs as SQL Agent sees them, next to msdb.dbo.cdc_jobs
SELECT DB_NAME(cj.database_id) AS database_name,
       cj.job_type,
       cj.job_id,
       sj.name AS agent_job_name
FROM msdb.dbo.cdc_jobs AS cj
LEFT JOIN msdb.dbo.sysjobs AS sj
    ON sj.job_id = cj.job_id
ORDER BY database_name, cj.job_type;
GO


/* =========================================================
   5. CLEANUP: Disable CDC on each database
      Drops all change tables, functions, jobs and the cdc schema.
      Highlight and run each one on its own.
   ========================================================= */

USE MyDatabase;
GO
EXEC sys.sp_cdc_disable_db;
GO

USE YourDatabase;
GO
EXEC sys.sp_cdc_disable_db;
GO

USE TheirDatabase;
GO
EXEC sys.sp_cdc_disable_db;
GO