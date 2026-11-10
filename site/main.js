// Copy-to-clipboard for every <button class="copy"> inside a .cmd block.
// Delegated so buttons created later (the detail panel) work too.
const resetTimers = new WeakMap();
document.addEventListener("click", async (event) => {
  const btn = event.target.closest("button.copy");
  if (!btn) return;
  const code = btn.parentElement.querySelector("code");
  if (!code) return;
  try {
    await navigator.clipboard.writeText(code.textContent);
    btn.textContent = "Copied";
  } catch {
    btn.textContent = "Press ⌘/Ctrl+C";
    const range = document.createRange();
    range.selectNodeContents(code);
    const sel = window.getSelection();
    sel.removeAllRanges();
    sel.addRange(range);
  }
  // One reset timer per button, so a second click restarts the 1.6s window
  // instead of the first click's timer cutting it short.
  clearTimeout(resetTimers.get(btn));
  resetTimers.set(btn, setTimeout(() => { btn.textContent = "Copy"; }, 1600));
});

// Theme toggle: flips between light and dark. With no saved choice the page
// follows the OS setting; the first click saves an explicit one.
(() => {
  const btn = document.querySelector(".theme-toggle");
  if (!btn) return;
  const root = document.documentElement;
  const osDark = window.matchMedia("(prefers-color-scheme: dark)");
  const current = () => root.dataset.theme || (osDark.matches ? "dark" : "light");
  const label = () => {
    const next = current() === "dark" ? "light" : "dark";
    btn.dataset.next = next;
    btn.setAttribute("aria-label", `Switch to ${next} theme`);
  };
  btn.addEventListener("click", () => {
    const next = current() === "dark" ? "light" : "dark";
    root.dataset.theme = next;
    try { localStorage.setItem("skein-theme", next); } catch {}
    label();
  });
  osDark.addEventListener("change", label);
  label();
})();
