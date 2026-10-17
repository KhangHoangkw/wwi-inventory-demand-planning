"""Builds images/service_trend.png from gold.vw_customer_service_monthly."""
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

fill = [99.54,98.65,98.75,98.66,97.83,98.42,98.26,97.40,97.13,97.13,97.43,97.37,97.22,97.38,97.62,96.14,96.34,96.13,96.72,96.46,96.61,96.23,95.77,95.45,95.99,96.06,96.04,95.16,94.44,94.50,94.67,95.50,94.70,94.41,93.81,93.65,94.41,95.17,95.08,94.28,93.73]
days = [1.06,1.17,1.12,1.25,1.27,1.35,1.41,1.62,1.47,1.67,1.58,1.88,1.64,1.85,2.15,2.08,1.75,2.01,1.69,2.47,2.68,2.08,2.54,2.47,2.43,2.31,2.98,2.31,2.51,2.41,2.59,3.27,2.44,3.49,3.72,3.59,3.14,3.69,3.89,3.43,3.68]
x = list(range(len(fill)))
ticks = [0, 12, 24, 36]; tick_labels = ["Jan 2013", "Jan 2014", "Jan 2015", "Jan 2016"]
BLUE, TEXT, TEXT2, GRID, SURF = "#2a78d6", "#0b0b0b", "#52514e", "#e4e3df", "#fcfcfb"

fig, axes = plt.subplots(1, 2, figsize=(11, 4.2), dpi=150)
fig.patch.set_facecolor(SURF)
panels = [(axes[0], fill, "Unit fill rate (%)", "{:.1f}%"), (axes[1], days, "Order-to-delivery (days)", "{:.1f} d")]
for ax, y, title, fmt in panels:
    ax.set_facecolor(SURF)
    ax.plot(x, y, color=BLUE, lw=2)
    ax.scatter([x[0], x[-1]], [y[0], y[-1]], s=40, color=BLUE, edgecolor=SURF, linewidth=2, zorder=3)
    up = y[-1] > y[0]
    ax.annotate(fmt.format(y[0]), (x[0], y[0]), textcoords="offset points",
                xytext=(6, -14 if up else 6), fontsize=9, color=TEXT)
    ax.annotate(fmt.format(y[-1]), (x[-1], y[-1]), textcoords="offset points",
                xytext=(7, -3), fontsize=9, color=TEXT, ha="left")
    ax.set_xlim(-1.5, len(y) + 4)
    ax.set_title(title, loc="left", fontsize=11, color=TEXT)
    ax.set_xticks(ticks); ax.set_xticklabels(tick_labels)
    ax.grid(True, axis="y", color=GRID, lw=0.8); ax.set_axisbelow(True)
    for s in ["top", "right"]: ax.spines[s].set_visible(False)
    for s in ["left", "bottom"]: ax.spines[s].set_color(GRID)
    ax.tick_params(colors=TEXT2, labelsize=9)
fig.suptitle("Service eroded as order volume grew ~9% a year (monthly, Jan 2013 - May 2016)",
             x=0.01, ha="left", fontsize=12, color=TEXT)
fig.tight_layout(rect=(0, 0, 1, 0.93))
fig.savefig("images/service_trend.png", facecolor=SURF)
print("saved")
