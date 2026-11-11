/* Footer privacy: the analytics snippet (added in Netlify) drops a raw privacy notice and a
   "Privacy settings" link at the very end of the page. Tidy them into the footer: a collapsed
   notice card, plus "Privacy" and "Privacy settings" links beside the other footer links. */
(() => {
  const ID = "cg-website-privacy";
  const GLANCE = [
    "Google Analytics: only if you accept",
    "Cloudflare analytics: no cookies",
    "No advertising features",
    "The apps are separate",
  ];
  function tidy() {
    const nav = document.querySelector(".footer-links");
    const inner = document.querySelector(".footer-inner");
    const section = document.getElementById(ID);
    if (!nav || !inner) return;
    const settings = document.getElementById("cg-analytics-settings");
    if (settings && settings.parentElement !== nav) nav.appendChild(settings);
    if (!section || section.dataset.tidy) return;
    section.dataset.tidy = "1";

    const title = section.querySelector("h2");
    const paragraphs = [...section.querySelectorAll(":scope > p")];
    const details = document.createElement("details");
    details.className = "privacy-details";
    const summary = document.createElement("summary");
    summary.id = "cg-website-privacy-title";
    summary.textContent = (title && title.textContent) || "Website privacy and analytics";
    const body = document.createElement("div");
    body.className = "privacy-body";
    const glance = document.createElement("ul");
    glance.className = "privacy-glance";
    for (const text of GLANCE) {
      const li = document.createElement("li");
      li.textContent = text;
      glance.appendChild(li);
    }
    body.append(glance, ...paragraphs);
    details.append(summary, body);
    section.replaceChildren(details);
    section.classList.add("privacy-block");
    inner.appendChild(section);

    const link = document.createElement("a");
    link.href = "#" + ID;
    link.textContent = "Privacy";
    nav.insertBefore(link, settings && settings.parentElement === nav ? settings : null);

    const reveal = () => { if (location.hash === "#" + ID) details.open = true; };
    window.addEventListener("hashchange", reveal);
    document.addEventListener("click", (e) => {
      if (e.target.closest && e.target.closest('a[href="#' + ID + '"]')) details.open = true;
    });
    reveal();
  }
  // The snippet runs around DOMContentLoaded; try again shortly in case it's late.
  document.addEventListener("DOMContentLoaded", tidy);
  window.addEventListener("load", () => { tidy(); setTimeout(tidy, 800); });
})();
