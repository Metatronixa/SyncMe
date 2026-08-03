(function () {
  "use strict";

  var yearEl = document.getElementById("year");
  if (yearEl) {
    yearEl.textContent = String(new Date().getFullYear());
  }

  var github = document.body.getAttribute("data-github");
  if (github) {
    document.querySelectorAll("a.js-github").forEach(function (link) {
      link.setAttribute("href", github);
    });
  }

  document.querySelectorAll('.navbar-nav .nav-link[href^="#"]').forEach(function (link) {
    link.addEventListener("click", function () {
      var collapse = document.getElementById("navMain");
      if (collapse && collapse.classList.contains("show")) {
        var toggler = document.querySelector(".navbar-toggler");
        if (toggler && window.getComputedStyle(toggler).display !== "none") {
          toggler.click();
        }
      }
    });
  });
})();
