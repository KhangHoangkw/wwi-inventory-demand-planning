# Data catalog: gold layer (`WWI_Analytics.gold`)

Grain = one row per … ; **key** in bold. Built by the procedures named in README.

## Dimensions
| Table | Grain | Columns |
|---|---|---|
| dim_date | day 2013-01-01 → 2016-12-31 (1,461) | **date_key** (yyyymmdd), date, year, quarter, month, month_name, month_start, iso_week, week_start_monday, weekday_no (1 = Mon), weekday_name, is_trading_day (0 = Sunday), model_period (calibration ≤ 2015-05-31 / test ≤ 2016-05-31 / future) |
| dim_stock_item | SKU (227), SCD Type 1 | **stock_item_id**, stock_item_name, brand, size, color, unit_package, outer_package, quantity_per_outer, declared_lead_time_days, is_chiller_stock, unit_price, recommended_retail_price, last_cost_price, erp_reorder_level, erp_target_stock_level, erp_quantity_on_hand (not trusted, see DQ), supplier_name, primary_stock_group, stock_groups (comma list) |
| bridge_stock_item_group | SKU × stock group (442) | **stock_item_id, stock_group_id**, stock_group_name |
| dim_customer | customer (663) | **customer_id**, customer_name, customer_category, buying_group, city_name, state_name, sales_territory, has_attributes (0 until the RLS grant) |
| dim_supplier | supplier (13) | **supplier_id**, supplier_name, supplier_category, payment_days |
| dim_delivery_method | delivery method (10) | **delivery_method_id**, delivery_method_name |
| dim_policy_scenario | scenario (17) | **scenario_id**, service_level (target CSL or fill rate), z (CSL only), lt_scenario (declared / mid 7d / actual 3d), scenario_name, target_type (CSL / FR / ERP) |

## Facts
| Table | Grain | Columns |
|---|---|---|
| fact_order_line | order line (231,412) | **order_line_id**, order_id, order_date_key, order_date, expected_delivery_date, customer_id, stock_item_id, quantity, picked_quantity, unshipped_quantity, unit_price, line_value_excl_tax, is_backorder_line (line on a backorder child order), order_was_split, is_never_picked |
| fact_invoice_line | invoice line (228,265) | **invoice_line_id**, invoice_id, order_id, invoice_date_key, invoice_date, order_date, expected_delivery_date, confirmed_delivery_date, customer_id, stock_item_id, delivery_method_id, quantity, unit_price, revenue_excl_tax, tax_amount, line_profit, days_order_to_delivery, is_on_time (NULL = no confirmation) |
| fact_purchase_order_line | PO line (8,367) | **purchase_order_line_id**, purchase_order_id, supplier_id, stock_item_id, order_date, expected_delivery_date, last_receipt_date, ordered_outers, received_outers, expected_unit_price_per_outer, actual_lead_days, expected_lead_days, declared_lead_time_days |
| fact_demand_daily | SKU × calendar day, zero-filled (283,069) | **stock_item_id, date_key**, date, demand_qty, order_lines |
| fact_demand_monthly | SKU × month (9,307) | **stock_item_id, month_start**, month_key, days_in_month, model_period, demand_units, demand_value, order_lines |
| fact_forecast | SKU × model × month (from 2014-01) | **stock_item_id, model, month_start**, model_period, forecast_units, actual_units, error_units (F − A), abs_error_units |
| fact_policy_simulation | run_type × scenario × SKU × day (1,362,618) | **run_type, scenario_id, stock_item_id, date_key**, demand_qty, filled_qty, receipt_qty, order_qty, net_inventory_end, on_hand_end, backlog_end, on_order_end |

## Planning / reference tables
| Table | Grain | Columns |
|---|---|---|
| sku_classification | SKU (227) | **stock_item_id**, calib_revenue, calib_units, mean_monthly_units, sd_monthly_units, zero_months, months, cum_revenue_share, cv (monthly), weekly_cv, abc_class (A/B/C/N), xyz_class (X/Y/Z/N), is_new_product |
| seasonal_index | calendar month (12) | **month**, seasonal_index |
| forecast_model_selection | SKU (219) | **stock_item_id**, selected_model, wape_calib |
| forecast_accuracy | window × model (8) | window_ (calibration / test), model (MA3 / SNAIVE / SEAS / SELECTED), wape, bias, mape, sku_months |
| normal_loss_table | k = −2.00 … 4.00 step 0.01 (601) | **k**, pdf, cdf (Abramowitz-Stegun), loss = G(k) |
| bootstrap_draws | rep × draw (1,000 × 250) | **rep, k**, h = deterministic hash (SHA-256 of "wwi-rep-k") used to resample SKUs with replacement |
| robustness_result | metric (14) | check_group, metric, value, ci_low, ci_high (95% bootstrap interval), note: built by `gold.usp_robustness_checks` |
| policy_parameters | scenario × SKU × test month (44,676) | **scenario_id, stock_item_id, month_start**, mu_d, sigma_d, e_rel, lt_days, quantity_per_outer, sigma_lt, safety_stock, reorder_point, order_up_to |

## Views
| View | Grain | Purpose |
|---|---|---|
| vw_policy_kpi_sku | run_type × scenario × SKU | fill_rate, ready_rate, avg_on_hand_units/value, cogs_value, purchase_orders, max_backlog_units |
| vw_policy_kpi_scenario | run_type × scenario | fill_rate, avg_inventory_value/units, inventory_turns, days_of_supply, target_gap, skus_below_target |
| vw_customer_service_monthly | month | order_split_rate, unit_fill_rate, lines_never_picked, units_on_backorder, on_time_delivery_rate, avg_days_order_to_delivery |
| vw_backorder_by_sku | SKU | units_on_backorder, backorder_unit_share, units_never_shipped, backorder_rank |
| vw_policy_kpi_monthly | run_type × scenario × month | fill_rate, avg_inventory_value (month-by-month policy comparison) |
| vw_forecast_accuracy_monthly | month × model (from 2014-01) | wape, bias, window_, rank_in_month (1 = best model that month) |
| vw_robustness_result | metric | robustness_result with readable metric names and formatted value / 95% CI text |
| vw_pbi_stock_item | SKU | dim_stock_item + ABC/XYZ for Power BI |
| vw_lead_time_audit | SKU | declared vs actual lead time, lead_time_overstatement_days, excess_inventory_value (declared vs actual-3d @95%) |

## ETL / quality (`etl` schema)
`bronze_config` (25 source tables), `load_log` (one row per table per run; layer bronze / silver / gold), `watermark` (incremental high-water marks), `dq_result` (run_id, check_name, layer, failed_rows, severity, detail), `vw_pipeline_fingerprint` (row count + check total for 11 key outputs) and `pipeline_fingerprint_snapshot` (saved fingerprints, e.g. "before full re-run" / "after full re-run", which were identical).

## Expected pipeline fingerprint
`SELECT * FROM etl.vw_pipeline_fingerprint;` after `EXEC etl.usp_run_pipeline @bronze_mode = 'full';` should return:

| object_name | row_count | check_total |
|---|---:|---:|
| gold.dim_customer | 663 | 663 |
| gold.dim_stock_item | 227 | 5,107.92 |
| gold.fact_demand_daily | 283,069 | 9,310,904 |
| gold.fact_demand_monthly | 9,307 | 9,310,904 |
| gold.fact_forecast | 19,053 | 19,656,215.75 |
| gold.fact_invoice_line | 228,265 | 172,261,341.20 |
| gold.fact_order_line | 231,412 | 9,310,904 |
| gold.fact_policy_simulation | 1,362,618 | 498,075,805.48 |
| gold.policy_parameters | 44,676 | 9,215,503.18 |
| gold.sku_classification | 227 | 69 |
| gold.vw_policy_kpi_scenario | 17 | 29,362,633.83 |
