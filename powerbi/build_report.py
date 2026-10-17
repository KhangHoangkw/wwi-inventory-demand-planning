"""
Generate the 6 report pages of WWI_Planning.Report (PBIR format) from a compact spec.

Usage (Power BI Desktop must NOT have the project open while this runs):
    python powerbi/build_report.py
Then open powerbi/WWI_Planning.pbip in Power BI Desktop.

The semantic model (tables, relationships, measures) lives in WWI_Planning.SemanticModel
and is not touched by this script. Visual files of the pages defined here are overwritten; other page folders must be removed first.
"""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent / "WWI_Planning.Report" / "definition"
PAGES_DIR = ROOT / "pages"

SCHEMA_PAGE = "https://developer.microsoft.com/json-schemas/fabric/item/report/definition/page/2.1.0/schema.json"
SCHEMA_PAGES = "https://developer.microsoft.com/json-schemas/fabric/item/report/definition/pagesMetadata/1.1.0/schema.json"
SCHEMA_VISUAL = "https://developer.microsoft.com/json-schemas/fabric/item/report/definition/visualContainer/2.4.0/schema.json"

W, H = 1280, 720
AGG = {"sum": 0, "avg": 1, "count": 2, "min": 3, "max": 4}


# ---------- field helpers ----------
def M(table, name):
    """measure reference"""
    return {"kind": "measure", "table": table, "name": name}


def C(table, name, agg=None, label=None):
    """column reference, optionally aggregated"""
    return {"kind": "column", "table": table, "name": name, "agg": agg, "label": label}


def lit(v):
    return {"expr": {"Literal": {"Value": v}}}


def field_expr(f):
    src = {"Expression": {"SourceRef": {"Entity": f["table"]}}, "Property": f["name"]}
    if f["kind"] == "measure":
        return {"Measure": src}, f"{f['table']}.{f['name']}", f["name"]
    col = {"Column": src}
    if f.get("agg") is not None:
        fn = AGG[f["agg"]]
        ref = f"{f['agg'].capitalize()}({f['table']}.{f['name']})"
        return {"Aggregation": {"Expression": col, "Function": fn}}, ref, f["name"]
    return col, f"{f['table']}.{f['name']}", f["name"]


def projection(f):
    expr, ref, native = field_expr(f)
    p = {"field": expr, "queryRef": ref, "nativeQueryRef": f.get("label") or native}
    if f.get("label"):
        p["displayName"] = f["label"]
    return p


# ---------- filters ----------
def cat_filter(name, table, column, values, exclude=False):
    """values: list of DAX-literal strings, e.g. "'SEAS'" or "3L" """
    cond = {"In": {
        "Expressions": [{"Column": {"Expression": {"SourceRef": {"Source": "t"}}, "Property": column}}],
        "Values": [[{"Literal": {"Value": v}}] for v in values],
    }}
    if exclude:
        cond = {"Not": {"Expression": cond}}
    return {
        "name": name,
        "field": {"Column": {"Expression": {"SourceRef": {"Entity": table}}, "Property": column}},
        "type": "Categorical",
        "filter": {"Version": 2, "From": [{"Name": "t", "Entity": table, "Type": 0}],
                   "Where": [{"Condition": cond}]},
    }


def csl95_filters():
    """95% cycle-service-level scenarios, one per lead-time assumption (no hard-coded ids)."""
    return [cat_filter("f_tt", "Scenario", "target_type", ["'CSL'"]),
            cat_filter("f_sl", "Scenario", "service_level", ["0.95M"])]


# ---------- visual builder ----------
class Page:
    def __init__(self, pid, title, subtitle, drillthrough_field=None):
        self.pid, self.title, self.subtitle = pid, title, subtitle
        self.drillthrough_field = drillthrough_field   # column ref -> drill-through page
        self.visuals = []
        self.z = 0
        self.textbox(title, subtitle, 16, 8, W - 32, 56)

    def _add(self, vid, x, y, w, h, visual, filters=None):
        self.z += 1000
        v = {
            "$schema": SCHEMA_VISUAL,
            "name": vid,
            "position": {"x": x, "y": y, "z": self.z, "height": h, "width": w, "tabOrder": self.z},
            "visual": visual,
        }
        if filters:
            v["filterConfig"] = {"filters": filters}
        self.visuals.append(v)

    def textbox(self, text, sub, x, y, w, h):
        paras = [{"textRuns": [{"value": text, "textStyle": {"fontWeight": "bold", "fontSize": "20pt"}}]}]
        if sub:
            paras.append({"textRuns": [{"value": sub, "textStyle": {"fontSize": "10pt", "color": "#605E5C"}}]})
        self._add(f"{self.pid}_title", x, y, w, h, {
            "visualType": "textbox",
            "objects": {"general": [{"properties": {"paragraphs": paras}}]},
            "drillFilterOtherVisuals": True,
        })

    def chart(self, vid, vtype, x, y, w, h, title, roles, sort=None, filters=None, objects=None, show_title=True):
        query_state = {role: {"projections": [projection(f) for f in fields]} for role, fields in roles.items()}
        query = {"queryState": query_state}
        if sort:
            f, direction = sort
            expr, _, _ = field_expr(f)
            query["sortDefinition"] = {"sort": [{"field": expr, "direction": direction}], "isDefaultSort": True}
        visual = {
            "visualType": vtype,
            "query": query,
            "visualContainerObjects": {
                "title": [{"properties": {"show": lit("true" if show_title else "false"),
                                          "text": lit("'" + title.replace("'", "''") + "'")}}],
                "subTitle": [{"properties": {"show": lit("false")}}]},
            "drillFilterOtherVisuals": True,
        }
        objects = dict(objects or {})
        if vtype == "tableEx":
            objects.setdefault("total", [{"properties": {"totals": lit("false")}}])
        if objects:
            visual["objects"] = objects
        self._add(f"{self.pid}_{vid}", x, y, w, h, visual, filters)

    def card(self, vid, x, y, w, h, title, f):
        f = dict(f, label=title)
        self.chart(vid, "card", x, y, w, h, title, {"Values": [f]}, show_title=False)

    def slicer(self, vid, x, y, w, h, title, f, single=False, dropdown=False):
        objs = {"header": [{"properties": {"show": lit("false")}}]}
        if dropdown:
            objs["data"] = [{"properties": {"mode": lit("'Dropdown'")}}]
        if single:
            objs["selection"] = [{"properties": {"singleSelect": lit("true")}}]
        self.chart(vid, "slicer", x, y, w, h, title, {"Values": [f]}, objects=objs)

    def write(self):
        d = PAGES_DIR / self.pid
        (d / "visuals").mkdir(parents=True, exist_ok=True)
        page = {"$schema": SCHEMA_PAGE, "name": self.pid, "displayName": self.title,
                "displayOption": "FitToPage", "height": H, "width": W}
        if self.drillthrough_field:
            f = self.drillthrough_field
            expr, _, _ = field_expr(f)
            page["type"] = "Drillthrough"
            page["visibility"] = "HiddenInViewMode"
            page["pageBinding"] = {"name": f"{self.pid}_binding", "type": "Drillthrough",
                                   "parameters": [{"name": f"{self.pid}_param", "boundFilter": f"{self.pid}_dt",
                                                   "fieldExpr": expr}]}
            page["filterConfig"] = {"filters": [{"name": f"{self.pid}_dt", "field": expr,
                                                 "type": "Categorical", "howCreated": "Drillthrough"}]}
        # visuals no longer in the spec are moved out (this environment cannot delete files)
        existing = {x.name for x in (d / "visuals").iterdir() if x.is_dir()}
        for stale in existing - {v["name"] for v in self.visuals}:
            target = ROOT.parent.parent / "_to_delete" / f"{self.pid}__{stale}"
            target.parent.mkdir(exist_ok=True)
            (d / "visuals" / stale).rename(target)
        (d / "page.json").write_text(json.dumps(page, indent=2), encoding="utf-8")
        for v in self.visuals:
            vd = d / "visuals" / v["name"]
            vd.mkdir(parents=True, exist_ok=True)
            (vd / "visual.json").write_text(json.dumps(v, indent=2), encoding="utf-8")


# ---------- shorthand tables ----------
IL, OL, FC, FA = "Invoice Line", "Order Line", "Forecast", "Forecast Accuracy"
SIM, SC, SK, SI = "Simulation", "Scenario", "Scenario KPI", "Stock Item"
PP, LTA, SM, BO = "Policy Parameters", "Lead Time Audit", "Service Monthly", "Backorder by SKU"
DQ, LL, DT, TSL = "DQ Results", "Load Log", "Date", "Target SL"

pages = []

# 1 ─ S&OP overview
p = Page("p1_overview", "S&OP overview",
         "Wide World Importers · actual sales & service 2013-01 → 2016-05 · forecast = SEAS model")
cw, gap = 240, 12
for i, (vid, t, f) in enumerate([
        ("rev", "Revenue (excl. tax)", M(IL, "Revenue")),
        ("gm", "Gross margin %", M(IL, "Gross Margin %")),
        ("units", "Units ordered", M(OL, "Units Ordered")),
        ("fill", "Unit fill rate", M(OL, "Unit Fill Rate")),
        ("otd", "On-time delivery %", M(IL, "On-Time Delivery %"))]):
    p.card(vid, 16 + i * (cw + gap), 72, cw, 96, t, f)
p.chart("trend", "lineChart", 16, 174, 820, 290, "Monthly units: actual vs SEAS forecast",
        {"Category": [C(DT, "month_start")],
         "Y": [dict(M(FC, "Actual Units (fc)"), label="Actual units"), dict(M(FC, "Forecast Units"), label="SEAS forecast")]},
        filters=[cat_filter("f_model", FC, "model", ["'SEAS'"])])
p.slicer("yr", 848, 174, 416, 90, "Year", C(DT, "year"), dropdown=True)
p.chart("byyear", "tableEx", 16, 476, 1248, 228, "KPI trend by year (*YoY vs same dates a year earlier; 2016 = Jan–May)",
        {"Values": [C(DT, "year", label="Year"), M(IL, "Revenue"), dict(M(IL, "Revenue YoY % (same period)"), label="Revenue YoY*"),
                    dict(M(IL, "Gross Margin %"), label="GM %"), M(OL, "Units Ordered"),
                    dict(M(OL, "Units YoY % (same period)"), label="Units YoY*"),
                    dict(M(OL, "Unit Fill Rate"), label="Fill rate"), dict(M(OL, "Backorder Unit Share"), label="Backorder share"),
                    dict(M(IL, "On-Time Delivery %"), label="OTD %"), dict(M(IL, "Avg Days Order to Delivery"), label="Days to deliver")]},
        sort=(C(DT, "year"), "Ascending"))
p.chart("revgrp", "clusteredBarChart", 848, 276, 416, 188, "Revenue by stock group",
        {"Category": [C(SI, "primary_stock_group")], "Y": [M(IL, "Revenue")]},
        sort=(M(IL, "Revenue"), "Descending"))
pages.append(p)

# 2 ─ Demand & forecast
p = Page("p2_forecast", "Demand & forecast",
         "Forecast accuracy by model (calibration 2013-01→2015-05, out-of-sample test 2015-06→2016-05) · ABC-XYZ segmentation")
p.chart("wape", "clusteredColumnChart", 16, 72, 500, 290, "WAPE by model and window",
        {"Category": [C(FA, "model")], "Series": [C(FA, "window_")], "Y": [C(FA, "wape", "sum", "WAPE")]})
p.chart("acc", "tableEx", 16, 374, 500, 330, "Forecast accuracy summary",
        {"Values": [C(FA, "window_"), C(FA, "model"), C(FA, "wape", "sum", "WAPE"), C(FA, "bias", "sum", "Bias"),
                    C(FA, "mape", "sum", "MAPE"), C(FA, "sku_months", "sum", "SKU-months")]})
p.slicer("sku", 528, 72, 360, 64, "Stock item", C(SI, "stock_item_name"), dropdown=True)
p.slicer("abc", 900, 72, 364, 64, "ABC class", C(SI, "abc_class"), dropdown=True)
p.chart("skuline", "lineChart", 528, 148, 736, 260, "Actual vs SEAS forecast (filter a SKU above)",
        {"Category": [C(DT, "month_start")],
         "Y": [dict(M(FC, "Actual Units (fc)"), label="Actual units"), dict(M(FC, "Forecast Units"), label="SEAS forecast")]},
        filters=[cat_filter("f_model", FC, "model", ["'SEAS'"])])
p.chart("abcxyz", "pivotTable", 528, 420, 360, 284, "ABC-XYZ matrix: number of SKUs",
        {"Rows": [C(SI, "abc_class")], "Columns": [C(SI, "xyz_class")],
         "Values": [C(SI, "stock_item_id", "count", "SKUs")]})
p.chart("wapeabc", "clusteredBarChart", 900, 420, 364, 284, "Test-window WAPE by ABC class (SEAS)",
        {"Category": [C(SI, "abc_class")], "Y": [M(FC, "WAPE")]},
        filters=[cat_filter("f_model", FC, "model", ["'SEAS'"]),
                 cat_filter("f_period", FC, "model_period", ["'test'"])])
pages.append(p)

# 3 ─ Policy simulation
p = Page("p3_policy", "Policy simulation",
         "(s, S) replay on actual daily demand, test year 2015-06→2016-05 · 16 scenarios on the frontier (ERP parameters excluded: 1.5% fill)")
p.chart("frontier", "scatterChart", 16, 72, 620, 320, "Service vs inventory frontier",
        {"Category": [C(SK, "scenario_name")], "Series": [C(SK, "lt_scenario")],
         "X": [C(SK, "avg_inventory_value", "sum", "Avg inventory value")],
         "Y": [C(SK, "fill_rate", "sum", "Fill rate")]},
        filters=[cat_filter("f_erp", SC, "target_type", ["'ERP'"], exclude=True)])
p.chart("invtrend", "lineChart", 648, 72, 616, 320, "Avg inventory value by month at 95% CSL, by lead-time assumption",
        {"Category": [C(DT, "month_start")], "Series": [C(SC, "lt_scenario")], "Y": [M(SIM, "Sim Avg Inventory Value")]},
        filters=csl95_filters())
p.chart("sctable", "tableEx", 16, 404, 1248, 300, "All 17 scenarios",
        {"Values": [C(SK, "scenario_id"), C(SK, "scenario_name"), C(SC, "target_type"),
                    C(SK, "service_level", "sum", "Target"), C(SK, "fill_rate", "sum", "Fill rate"),
                    C(SK, "target_gap", "sum", "Target gap"), C(SK, "avg_inventory_value", "sum", "Avg inventory value"),
                    C(SK, "inventory_turns", "sum", "Turns"), C(SK, "days_of_supply", "sum", "Days of supply"),
                    C(SK, "purchase_orders", "sum", "POs"), C(SK, "skus_below_target", "sum", "SKUs below target")]},
        sort=(C(SK, "scenario_id"), "Ascending"))
pages.append(p)

# 4 ─ Planning-parameter audit
p = Page("p4_audit", "Planning-parameter audit",
         "Declared vs recorded PO lead times · excess inventory IF recorded lead times hold (WWI purchasing data is partly synthetic) · safety-stock what-if · right-click a SKU → Drill through")
p.card("ltdecl", 16, 72, 200, 100, "Declared lead time (d)", C(LTA, "declared_lead_time_days", "avg"))
p.card("ltact", 228, 72, 200, 100, "Recorded LT (d)", C(LTA, "avg_actual_lead_days", "avg"))
p.card("excess", 440, 72, 220, 100, "Excess inventory @95%", C(LTA, "excess_inventory_value", "sum"))
p.chart("bysup", "clusteredBarChart", 16, 184, 320, 250, "Excess inventory by supplier",
        {"Category": [C(LTA, "supplier_name")], "Y": [C(LTA, "excess_inventory_value", "sum", "Excess value")]},
        sort=(C(LTA, "excess_inventory_value", "sum"), "Descending"))
p.chart("bygrp", "clusteredBarChart", 348, 184, 312, 250, "Excess inventory by stock group",
        {"Category": [C(SI, "primary_stock_group")], "Y": [C(LTA, "excess_inventory_value", "sum", "Excess value")]},
        sort=(C(LTA, "excess_inventory_value", "sum"), "Descending"))
p.slicer("tsl", 672, 72, 280, 100, "Target service level (what-if)", C(TSL, "Value"), single=True, dropdown=True)
p.card("tslv", 964, 72, 300, 100, "Selected target service level", M(TSL, "Target SL Value"))
p.chart("sswhatif", "tableEx", 672, 184, 592, 250, "Safety stock at the selected service level, by lead-time assumption",
        {"Values": [C(SC, "lt_scenario"), M(PP, "Safety Stock What-if (units)"), M(PP, "Safety Stock What-if (value)")]},
        filters=csl95_filters())
p.chart("ltable", "tableEx", 16, 446, 1248, 258, "Lead-time audit by SKU",
        {"Values": [C(SI, "stock_item_name", label="SKU"), C(LTA, "supplier_name", label="Supplier"),
                    C(LTA, "declared_lead_time_days", "sum", "Declared LT"), C(LTA, "avg_actual_lead_days", "sum", "Recorded LT"),
                    C(LTA, "lead_time_overstatement_days", "sum", "Overstatement (d)"),
                    C(LTA, "inv_value_declared_95", "sum", "Inv. value declared LT"),
                    C(LTA, "inv_value_actual3d_95", "sum", "Inv. value recorded LT"),
                    C(LTA, "excess_inventory_value", "sum", "Excess value")]},
        sort=(C(LTA, "excess_inventory_value", "sum"), "Descending"))
pages.append(p)

# 5 ─ Customer service
p = Page("p5_service", "Customer service",
         "Actual order fulfilment 2013-01 → 2016-05 · fill rate falling, order-to-delivery time rising · where backorders concentrate · right-click a SKU → Drill through")
p.chart("svc", "lineChart", 16, 72, 620, 300, "Unit fill rate and on-time delivery by month",
        {"Category": [C(SM, "month_start")],
         "Y": [C(SM, "unit_fill_rate", "sum", "Unit fill rate"), C(SM, "on_time_delivery_rate", "sum", "On-time delivery")]})
p.chart("days", "lineChart", 648, 72, 616, 300, "Average days from order to delivery",
        {"Category": [C(SM, "month_start")], "Y": [C(SM, "avg_days_order_to_delivery", "sum", "Days order→delivery")]})
p.chart("bogrp", "clusteredBarChart", 16, 384, 420, 320, "Backorder unit share by stock group",
        {"Category": [C(SI, "primary_stock_group")], "Y": [M(OL, "Backorder Unit Share")]},
        sort=(M(OL, "Backorder Unit Share"), "Descending"))
p.chart("bosku", "tableEx", 448, 384, 816, 320, "Backorders by SKU",
        {"Values": [C(BO, "backorder_rank", "min", "Rank"), C(SI, "stock_item_name", label="SKU"), C(SI, "primary_stock_group", label="Group"),
                    C(BO, "units_on_backorder", "sum", "Units on backorder"),
                    C(BO, "backorder_unit_share", "sum", "Backorder share")]},
        sort=(C(BO, "units_on_backorder", "sum"), "Descending"))
pages.append(p)

# 6 ─ Data quality & ETL
p = Page("p6_dq", "Data quality & ETL",
         "13 automated checks across bronze/silver/gold (latest run) · metadata-driven load log")
p.card("checks", 16, 72, 220, 100, "Checks in latest run", C(DQ, "check_name", "count"))
p.card("failed", 248, 72, 220, 100, "Failed rows (latest run)", C(DQ, "failed_rows", "sum"))
p.card("loads", 480, 72, 220, 100, "Load steps logged", C(LL, "log_id", "count"))
p.card("rows", 712, 72, 220, 100, "Rows loaded (all runs)", C(LL, "rows_affected", "sum"))
dq_run = [cat_filter("f_run", DQ, "is_latest_run", ["true"])]   # calculated column, no hard-coded run id
p.chart("dqtable", "tableEx", 16, 184, 800, 520, "Data-quality checks (latest run)",
        {"Values": [C(DQ, "layer"), C(DQ, "check_name"), C(DQ, "severity"),
                    C(DQ, "failed_rows", "sum", "Failed rows"), C(DQ, "detail")]},
        filters=dq_run)
p.chart("ll", "tableEx", 828, 184, 436, 520, "ETL load log",
        {"Values": [C(LL, "log_id", label="Log id"), C(LL, "layer"), C(LL, "object_name"),
                    C(LL, "rows_affected", "sum", "Rows"), C(LL, "status")]},
        sort=(C(LL, "log_id"), "Descending"))
# the two DQ cards also show the latest run only
for v in p.visuals:
    if v["name"] in ("p6_dq_checks", "p6_dq_failed"):
        v["filterConfig"] = {"filters": dq_run}
pages.append(p)

# 7 ─ Robustness checks
RB, PM, FAM = "Robustness", "Policy Monthly", "Forecast Accuracy Monthly"
p = Page("p7_robustness", "Robustness checks",
         "How much to trust the headline results: 1,000-resample SKU bootstrap, month-by-month and SKU-by-SKU consistency (sql/04_analysis/07_robustness_checks.sql)")
p.chart("rbtable", "tableEx", 16, 72, 1248, 340, "Robustness results (value, 95% CI where bootstrapped)",
        {"Values": [C(RB, "check_group"), C(RB, "metric_label", label="Metric"), C(RB, "value_text", label="Result"),
                    C(RB, "ci_95_text", label="95% CI"), C(RB, "note")]},
        sort=(C(RB, "check_group"), "Ascending"))
two_policies = [cat_filter("f_pol", SC, "scenario_name", ["'declared LT | SL 95.0%'", "'actual 3d LT | SL 99.0%'"])]
p.chart("polinv", "lineChart", 16, 424, 410, 280, "Inventory value by month: current vs recommended",
        {"Category": [C(PM, "month_start")], "Series": [C(SC, "scenario_name")],
         "Y": [C(PM, "avg_inventory_value", "sum", "Avg inventory value")]}, filters=two_policies)
p.chart("polfill", "lineChart", 436, 424, 410, 280, "Fill rate by month: current vs recommended",
        {"Category": [C(PM, "month_start")], "Series": [C(SC, "scenario_name")],
         "Y": [C(PM, "fill_rate", "sum", "Fill rate")]}, filters=two_policies)
p.chart("fcmonth", "lineChart", 856, 424, 408, 280, "Forecast WAPE by month and model",
        {"Category": [C(FAM, "month_start")], "Series": [C(FAM, "model")],
         "Y": [C(FAM, "wape", "sum", "WAPE")]},
        filters=[cat_filter("f_m", FAM, "model", ["'SEAS'", "'MA3'", "'SNAIVE'"])])
pages.append(p)

# 8 ─ SKU detail (drill-through target)
p = Page("p8_sku", "SKU detail",
         "Drill-through page: right-click a SKU on Planning-parameter audit or Customer service → Drill through → SKU detail",
         drillthrough_field=C(SI, "stock_item_name"))
p.chart("attr", "tableEx", 16, 72, 1248, 124, "SKU master data",
        {"Values": [C(SI, "stock_item_name", label="SKU"), C(SI, "primary_stock_group", label="Group"),
                    C(SI, "supplier_name", label="Supplier"), C(SI, "abc_class", label="ABC"), C(SI, "xyz_class", label="XYZ"), C(SI, "declared_lead_time_days", "max", "Declared LT (d)"),
                    C(SI, "quantity_per_outer", "max", "Pack size"), C(SI, "last_cost_price", "max", "Unit cost")]})
for i, (vid, t, f) in enumerate([
        ("units", "Units ordered", M(OL, "Units Ordered")),
        ("fill", "Unit fill rate (actual)", M(OL, "Unit Fill Rate")),
        ("bo", "Backorder unit share", M(OL, "Backorder Unit Share")),
        ("wape", "Forecast WAPE (SEAS, test)", M(FC, "WAPE"))]):
    p.card(vid, 16 + i * 316, 204, 304, 96, t, f)
p.visuals[-1]["filterConfig"] = {"filters": [cat_filter("f_model", FC, "model", ["'SEAS'"]),
                                             cat_filter("f_period", FC, "model_period", ["'test'"])]}
p.chart("fc", "lineChart", 16, 308, 620, 190, "Monthly demand: actual vs SEAS forecast",
        {"Category": [C(DT, "month_start")],
         "Y": [dict(M(FC, "Actual Units (fc)"), label="Actual units"), dict(M(FC, "Forecast Units"), label="SEAS forecast")]},
        filters=[cat_filter("f_model", FC, "model", ["'SEAS'"])])
p.chart("onhand", "lineChart", 648, 308, 616, 190, "Simulated on-hand units at 95% CSL, by lead-time assumption",
        {"Category": [C(DT, "date")], "Series": [C(SC, "lt_scenario")],
         "Y": [C(SIM, "on_hand_end", "sum", "On hand (units)")]}, filters=csl95_filters())
p.chart("params", "tableEx", 16, 506, 1248, 198, "Planning parameters by month at 95% CSL (safety stock, reorder point, order-up-to)",
        {"Values": [C(PP, "month_start"), C(SC, "lt_scenario"), C(PP, "lt_days", "max", "LT (d)"),
                    C(PP, "mu_d", "max", "Daily demand μ"), C(PP, "safety_stock", "max", "Safety stock"),
                    C(PP, "reorder_point", "max", "Reorder point"), C(PP, "order_up_to", "max", "Order-up-to")]},
        sort=(C(PP, "month_start"), "Ascending"), filters=csl95_filters())
pages.append(p)


def main():
    PAGES_DIR.mkdir(parents=True, exist_ok=True)
    keep = {pg.pid for pg in pages}
    stale = [d.name for d in PAGES_DIR.iterdir() if d.is_dir() and d.name not in keep]
    if stale:
        raise SystemExit(f"remove or move these old page folders first: {stale}")
    for pg in pages:
        pg.write()
    meta = {"$schema": SCHEMA_PAGES, "pageOrder": [pg.pid for pg in pages], "activePageName": pages[0].pid}
    (PAGES_DIR / "pages.json").write_text(json.dumps(meta, indent=2), encoding="utf-8")
    n = sum(len(pg.visuals) for pg in pages)
    print(f"wrote {len(pages)} pages, {n} visuals to {PAGES_DIR}")


if __name__ == "__main__":
    main()
