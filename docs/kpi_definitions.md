# KPI definitions (as implemented)

| KPI | Formula | Grain | Where |
|-----|---------|-------|-------|
| Revenue | Σ InvoiceLines.ExtendedPrice − TaxAmount (`revenue_excl_tax`) | invoice line | `gold.fact_invoice_line` |
| Gross profit / margin | Σ LineProfit ; margin = profit / revenue | invoice line | `gold.fact_invoice_line` |
| Demand (units) | Σ OrderLines.Quantity by **order date** (ordered, not shipped → not censored by stock-outs). Backorder child orders hold different lines than the parent, so there is no double counting | SKU × day / month | `gold.fact_demand_daily`, `gold.fact_demand_monthly` |
| ABC class | Cumulative revenue share in calibration window: A ≤ 80%, B ≤ 95%, C rest; N = new product | SKU | `gold.sku_classification` |
| XYZ class | Weekly CV (stdev / mean of weekly units, zero weeks included): X < 0.5, Y < 1.0, Z ≥ 1.0 | SKU | `gold.sku_classification` |
| Seasonal index | Month units / year average, averaged over 2013–2014 (company level) | month | `gold.seasonal_index` |
| Forecast SEAS | mean of last 12 deseasonalised months × SI(m) × (last 12 / previous 12)^(6.5/12) | SKU × month | `gold.fact_forecast` |
| WAPE | Σ\|F − A\| / Σ A | any aggregation | `gold.forecast_accuracy` |
| Bias | Σ(F − A) / Σ A (positive = over-forecast) | any aggregation | `gold.forecast_accuracy` |
| MAPE | mean(\|F − A\| / A) over months with A > 0 (reference only) | SKU × month | `gold.forecast_accuracy` |
| μ_d | SEAS forecast of month / days in month | SKU × month | `gold.policy_parameters` |
| σ_d | stdev of daily demand over the previous 365 days (zeros included) | SKU × month | `gold.policy_parameters` |
| e_rel | RMSE of SEAS monthly error over previous 12 months / mean monthly actual | SKU × month | `gold.policy_parameters` |
| σ_LT | √(LT·σ_d² + (LT·μ_d·e_rel)²) | SKU × month × scenario | `gold.policy_parameters` |
| Safety stock | z × σ_LT (z from cycle service level: 1.2816 / 1.6449 / 1.9600 / 2.3263) | SKU × month × scenario | `gold.policy_parameters` |
| Safety stock (fill-rate scenarios) | k × σ_LT, k = smallest k with G(k) ≤ (1 − β) × Q / σ_LT ; G(k) = φ(k) − k(1 − Φ(k)) ; Q = max(7 μ_d, pack size) ; floored at 0 | SKU × month × scenario 14–17 | `gold.policy_parameters`, `gold.normal_loss_table` |
| Reorder point | μ_d × LT + SS | SKU × month × scenario | `gold.policy_parameters` |
| Order-up-to (S) | ROP + 7 × μ_d ; order qty rounded up to QuantityPerOuter | SKU × month × scenario | `gold.policy_parameters` |
| Sim fill rate | Σ units served from stock on demand day / Σ units demanded | scenario (× SKU) | `gold.vw_policy_kpi_*` |
| Sim ready rate | days with demand fully served / days with demand | SKU | `gold.vw_policy_kpi_sku` |
| Sim avg inventory value | average end-of-day on hand × LastCostPrice | scenario × SKU | `gold.vw_policy_kpi_*` |
| Target gap | sim fill rate − target service level | scenario | `gold.vw_policy_kpi_scenario` |
| Inventory turns | cost of units shipped in the test year / average inventory value | scenario | `gold.vw_policy_kpi_scenario` |
| Days of supply (sim) | 366 / inventory turns | scenario | `gold.vw_policy_kpi_scenario` |
| Unit fill rate (actual) | Σ PickedQuantity / Σ Quantity | month / SKU | `gold.vw_customer_service_monthly` |
| Order split rate | original orders that spawned a backorder / original orders | month | `gold.vw_customer_service_monthly` |
| On-time delivery | invoices with confirmed delivery ≤ order ExpectedDeliveryDate / invoices with a confirmation (84 without confirmation excluded) | month | `gold.vw_customer_service_monthly` |
| Backorder unit share | units on backorder (child) orders / units ordered | SKU / stock group | `gold.vw_backorder_by_sku` |
| Lead-time overstatement | declared LeadTimeDays − average actual (PO order date → last receipt) | SKU | `gold.vw_lead_time_audit` |
| Excess inventory (lead time) | sim avg inventory value at declared LT @95% − at actual 3 d @95% | SKU | `gold.vw_lead_time_audit` |
| Revenue / Units YoY % (same period) | (value − value on the same dates one year earlier) / earlier value, dates capped at the last transaction date so 2016 (Jan–May) compares with Jan–May 2015 | year / month | DAX measures in `powerbi/measures.dax` |
| Bootstrap 95% CI | 2.5th–97.5th percentile over 1,000 resamples of the 219 SKUs (with replacement); the KPI is recomputed on each resample | metric | `gold.usp_robustness_checks` |
| Months ranked best | number of months in which a model has the lowest WAPE of the three (2015-01 … 2016-05, all out-of-sample) | model | `gold.vw_forecast_accuracy_monthly` |
