// node tests/preview-check.mjs  (with `creel preview` running)
// Every tab in both looks through the preview server: errors, unmodelled calls,
// regions that fall outside the window, and overlapping text.
const ask = async body => (await fetch("http://127.0.0.1:7878/render", { method: "POST", body: JSON.stringify(body) })).json();
let bad = 0;
for (const theme of ["standalone", "eui"]) {
  const options = { theme, zone: 1444, skill: 230, sample: true };
  const first = await ask({ options, actions: [] });
  if (first.error) { console.log(theme, "ERROR", first.error.slice(0, 500)); bad++; continue; }
  const win = first.nodes.find(n => n.name === "TightLinesFrame");
  const tabs = first.nodes.filter(n => n.k === "f" && n.click && n.h === 26 && n.w === 104);
  for (const [i, tab] of tabs.entries()) {
    const data = await ask({ options, actions: [{ type: "click", id: tab.id }] });
    if (data.error) { console.log(theme, "tab", i, "ERROR", data.error.slice(0, 500)); bad++; continue; }
    const label = data.nodes.find(n => n.k === "s" && n.f === tab.id)?.text;
    const outside = data.nodes.filter(n => n.k !== "f" && !n.hx && (n.x < win.x - 1 || n.y < win.y - 1 || n.x + n.w > win.x + win.w + 1 || n.y + n.h > win.y + win.h + 1));
    // Text regions of one frame that overlap each other vertically and horizontally
    const texts = data.nodes.filter(n => n.k === "s" && !n.hx && !n.vy);
    let overlaps = 0;
    for (let a = 0; a < texts.length; a++) for (let b = a + 1; b < texts.length; b++) {
      const p = texts[a], q = texts[b];
      if (p.f === q.f && p.x < q.x + q.w - 2 && q.x < p.x + p.w - 2 && p.y < q.y + q.h - 2 && q.y < p.y + p.h - 2) overlaps++;
    }
    const titles = data.nodes.filter(n => n.k === "s" && n.size >= 16).map(n => n.text.replace(/\|c\w{8}|\|r/g, "")).slice(1, 2);
    console.log(`${theme.padEnd(10)} ${String(label).padEnd(9)} regions ${String(data.nodes.length).padStart(4)}  errors ${data.errors.length}  unmodelled ${data.missing.length}  outside window ${outside.length}  overlapping text ${overlaps}  detail: ${titles[0] ?? "-"}`);
    if (data.errors.length || outside.length || overlaps) { bad++; if (data.errors[0]) console.log("   ", data.errors[0].slice(0, 300)); if (outside[0]) console.log("    outside:", JSON.stringify(outside[0]).slice(0, 200)); }
  }
}
console.log(bad ? `PROBLEMS: ${bad}` : "ALL TABS RENDER CLEANLY");
