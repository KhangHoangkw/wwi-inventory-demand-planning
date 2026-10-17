/* =====================================================================
   01_vw_pbi_stock_item.sql
   Power BI-facing product dimension: dim_stock_item + ABC/XYZ classification
   (one table in the model instead of a 1:1 relationship).
   ===================================================================== */
USE WWI_Analytics;
GO
CREATE OR ALTER VIEW gold.vw_pbi_stock_item
AS
SELECT  i.stock_item_id, i.stock_item_name, i.brand, i.size, i.color,
        i.unit_package, i.outer_package, i.quantity_per_outer, i.declared_lead_time_days,
        i.is_chiller_stock, i.unit_price, i.recommended_retail_price, i.last_cost_price,
        i.supplier_name, i.primary_stock_group, i.stock_groups,
        c.abc_class, c.xyz_class, CONCAT(c.abc_class, c.xyz_class) AS abc_xyz,
        c.is_new_product, c.weekly_cv, c.calib_revenue
FROM gold.dim_stock_item i
LEFT JOIN gold.sku_classification c ON c.stock_item_id = i.stock_item_id;
GO
