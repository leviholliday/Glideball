/* The small-screen menu is a plain <details>, so it works without this file.
   This only closes it after a link is picked, on Escape, or on a click outside. */
(() => {
  const menu = document.querySelector(".nav-menu");
  if (!menu) return;
  const close = () => { menu.open = false; };
  menu.addEventListener("click", (e) => { if (e.target.closest("a")) close(); });
  document.addEventListener("click", (e) => { if (menu.open && !menu.contains(e.target)) close(); });
  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape" && menu.open) { close(); menu.querySelector("summary").focus(); }
  });
})();
