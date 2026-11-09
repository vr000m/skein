// Runs in <head> before first paint so a saved theme choice never flashes.
(function () {
  try {
    var t = localStorage.getItem("skein-theme");
    if (t === "light" || t === "dark") document.documentElement.dataset.theme = t;
  } catch (e) {}
})();
