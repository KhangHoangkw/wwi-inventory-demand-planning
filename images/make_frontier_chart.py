"""Builds images/policy_frontier.png from the simulation KPIs
(gold.vw_policy_kpi_scenario, test year Jun-2015..May-2016)."""
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

# (label, inventory $M, fill rate %, target label)
data = {
    "Declared lead time (12-14 d), CSL target": [(1.000, 98.44, "90%"), (1.160, 99.39, "95%"), (1.304, 99.74, "97.5%"), (1.465, 99.92, "99%")],
    "7-day lead time, CSL target":             [(0.754, 98.57, "90%"), (0.861, 99.34, "95%"), (0.953, 99.67, "97.5%"), (1.062, 99.87, "99%")],
    "Actual lead time (3 d), CSL target":      [(0.578, 97.81, "90%"), (0.643, 98.72, "95%"), (0.700, 99.26, "97.5%"), (0.765, 99.60, "99%")],
    "Actual lead time (3 d), fill-rate target": [(0.470, 94.89, "95%"), (0.538, 97.02, "97.5%"), (0.615, 98.44, "99%"), (0.668, 99.00, "99.5%")],
}
colors  = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100"]   # validated categorical slots 1-4 (light)
markers = ["o", "s", "D", "^"]
TEXT, TEXT2, GRID, SURF = "#0b0b0b", "#52514e", "#e4e3df", "#fcfcfb"

fig, ax = plt.subplots(figsize=(10, 6.2), dpi=150)
fig.patch.set_facecolor(SURF); ax.set_facecolor(SURF)
for (name, pts), c, m in zip(data.items(), colors, markers):
    xs = [p[0] for p in pts]; ys = [p[1] for p in pts]
    ax.plot(xs, ys, color=c, lw=2, zorder=2)
    ax.scatter(xs, ys, s=64, color=c, marker=m, edgecolor=SURF, linewidth=2, zorder=3, label=name)
    for x, y, t in pts:
        ax.annotate(t, (x, y), textcoords="offset points", xytext=(6, -12), fontsize=8, color=TEXT2)

# highlight the headline comparison
ax.annotate("Declared lead time @95%: 99.39% fill, $1.16M", (1.160, 99.39), textcoords="offset points",
            xytext=(-10, -48), fontsize=9, color=TEXT, ha="center",
            arrowprops=dict(arrowstyle="-", color=TEXT2, lw=1))
ax.annotate("Actual lead time @99%: 99.60% fill, $0.77M (-34%)", (0.765, 99.60), textcoords="offset points",
            xytext=(-30, 26), fontsize=9, color=TEXT, ha="center",
            arrowprops=dict(arrowstyle="-", color=TEXT2, lw=1))

ax.set_xlabel("Average inventory value at cost (USD millions)", color=TEXT2, fontsize=10)
ax.set_ylabel("Fill rate from stock (%)", color=TEXT2, fontsize=10)
ax.set_title("Service vs inventory: 219 SKUs simulated on real daily demand, Jun 2015 - May 2016",
             loc="left", fontsize=12, color=TEXT, pad=26)
ax.text(0, 1.02, "Each point = one policy scenario; label = target level. ERP's current parameters (1.5% fill) are off-scale.",
        transform=ax.transAxes, fontsize=9, color=TEXT2)
ax.grid(True, color=GRID, lw=0.8); ax.set_axisbelow(True)
for s in ["top", "right"]: ax.spines[s].set_visible(False)
for s in ["left", "bottom"]: ax.spines[s].set_color(GRID)
ax.tick_params(colors=TEXT2, labelsize=9)
ax.set_xlim(0.40, 1.55); ax.set_ylim(94.5, 100.2)
leg = ax.legend(loc="lower right", fontsize=9, frameon=False)
for t in leg.get_texts(): t.set_color(TEXT)
fig.tight_layout()
fig.savefig("images/policy_frontier.png", facecolor=SURF)
print("saved")
