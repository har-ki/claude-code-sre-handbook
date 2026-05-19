document.querySelectorAll("a[href^='http']").forEach(function (a) {
  if (a.hostname !== location.hostname) {
    a.setAttribute("target", "_blank");
    a.setAttribute("rel", "noopener");
  }
});
