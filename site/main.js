// Copy-to-clipboard for every <button class="copy"> inside a .cmd block.
// Delegated so buttons created later (the detail panel) work too.
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
  setTimeout(() => { btn.textContent = "Copy"; }, 1600);
});
