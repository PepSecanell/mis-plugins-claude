/* Agent Teams site motion. No dependencies.
   - [data-reveal]: fades/rises in once when it enters the viewport.
   - [data-progress]: gets a --p custom property (0..1) from scroll position, read by CSS transforms.
   - #assemble: agents fly into place around Chief, lines draw, then "flow" once assembled.
   - #how: sticky chat that plays a scripted conversation per step. */
(function () {
  var doc = document.documentElement;
  var reduce = window.matchMedia("(prefers-reduced-motion: reduce)");
  var vh = window.innerHeight;
  function clamp(v, a, b) { return v < a ? a : v > b ? b : v; }
  function easeOut(t) { return 1 - Math.pow(1 - t, 3); }

  /* Nav background once scrolled */
  var nav = document.querySelector(".nav");
  function navState() { if (nav) nav.classList.toggle("scrolled", window.scrollY > 8); }

  /* Reveal on scroll */
  var groups = document.querySelectorAll("[data-stagger]");
  groups.forEach(function (g) {
    var step = parseInt(g.getAttribute("data-stagger"), 10) || 90;
    Array.prototype.forEach.call(g.querySelectorAll(":scope > [data-reveal]"), function (el, i) {
      el.style.setProperty("--rd", i * step + "ms");
    });
  });
  var revealEls = document.querySelectorAll("[data-reveal]");
  if ("IntersectionObserver" in window && !reduce.matches) {
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) {
        if (e.isIntersecting) { e.target.classList.add("in"); io.unobserve(e.target); }
      });
    }, { rootMargin: "0px 0px -12% 0px", threshold: 0.08 });
    revealEls.forEach(function (el) { io.observe(el); });
  } else {
    revealEls.forEach(function (el) { el.classList.add("in"); });
  }

  /* Scroll progress */
  var prog = Array.prototype.map.call(document.querySelectorAll("[data-progress]"), function (el) {
    return { el: el, mode: el.getAttribute("data-progress"), last: -1 };
  });
  function progressOf(item, r) {
    if (item.mode === "pin") return clamp(-r.top / Math.max(1, r.height - vh), 0, 1);
    if (item.mode === "leave") return clamp(-r.top / Math.max(1, r.height), 0, 1);
    /* "enter": 0 when the top touches the bottom of the viewport, 1 when the element's middle is centred */
    return clamp((vh - r.top) / (vh * 0.5 + r.height * 0.5), 0, 1);
  }

  /* Team assembling */
  var stage = document.getElementById("stage");
  var agents = stage ? Array.prototype.slice.call(stage.querySelectorAll(".agent")) : [];
  var lines = stage ? Array.prototype.slice.call(stage.querySelectorAll(".ln")) : [];
  var chief = stage ? stage.querySelector(".chief") : null;
  function assemble(p) {
    var n = agents.length;
    agents.forEach(function (a, i) {
      var start = 0.06 + i * 0.065;
      var e = easeOut(clamp((p - start) / 0.3, 0, 1));
      a.style.setProperty("--e", e.toFixed(4));
      if (lines[i]) lines[i].style.setProperty("--e", clamp((p - start - 0.08) / 0.25, 0, 1).toFixed(4));
    });
    if (chief) chief.style.setProperty("--ce", easeOut(clamp(p / 0.12, 0, 1)).toFixed(4));
    stage.style.setProperty("--r", easeOut(clamp((p - 0.5) / 0.22, 0, 1)).toFixed(4));
    stage.classList.toggle("done", p > 0.74 && n > 0);
  }

  /* Sticky chat */
  var how = document.getElementById("how");
  var mock = how ? how.querySelector(".mock") : null;
  var stepEls = how ? how.querySelectorAll(".step") : [];
  var dotEls = how ? how.querySelectorAll(".how-dots span") : [];
  var timed = mock ? Array.prototype.slice.call(mock.querySelectorAll("[data-s]")) : [];
  var curStep = 0, timers = [];
  function clearTimers() { timers.forEach(clearTimeout); timers = []; }
  function setStep(s) {
    if (s === curStep || !mock) return;
    var forward = s > curStep;
    curStep = s;
    clearTimers();
    stepEls.forEach(function (el, i) { el.classList.toggle("on", i + 1 === s); });
    dotEls.forEach(function (el, i) { el.classList.toggle("on", i + 1 === s); });
    mock.classList.toggle("chat2", s >= 3);
    timed.forEach(function (el) {
      var es = parseInt(el.getAttribute("data-s"), 10);
      var cls = el.getAttribute("data-cls") || "on";
      var t = parseInt(el.getAttribute("data-t") || "0", 10);
      var until = el.getAttribute("data-until");
      if (es < s || (es === s && (!forward || reduce.matches))) {
        /* Earlier steps (or jumping back): show the final state straight away. */
        el.classList.toggle(cls, until === null);
      } else if (es === s) {
        el.classList.remove(cls);
        timers.push(setTimeout(function () { el.classList.add(cls); }, t));
        if (until !== null) timers.push(setTimeout(function () { el.classList.remove(cls); }, parseInt(until, 10)));
      } else {
        el.classList.remove(cls);
      }
    });
  }
  function howUpdate(p) {
    var s = p < 0.3 ? 1 : p < 0.64 ? 2 : 3;
    setStep(s);
    /* little progress bar inside the active step (desktop list) */
    var ranges = [[0, 0.3], [0.3, 0.64], [0.64, 1]];
    stepEls.forEach(function (el, i) {
      var bar = el.querySelector(".bar");
      if (!bar) return;
      var r = ranges[i];
      bar.style.transform = "scaleY(" + clamp((p - r[0]) / (r[1] - r[0]), 0, 1).toFixed(3) + ")";
    });
  }

  /* Frame loop: only runs when the page has scrolled or resized */
  var ticking = false;
  function frame() {
    ticking = false;
    navState();
    for (var i = 0; i < prog.length; i++) {
      var it = prog[i];
      var r = it.el.getBoundingClientRect();
      if (r.bottom < -vh * 0.5 || r.top > vh * 1.5) continue;
      /* the chat waits until its section is actually on screen before it starts talking */
      if (it.el.id === "how" && curStep === 0 && r.top > vh * 0.45) continue;
      var p = progressOf(it, r);
      if (Math.abs(p - it.last) < 0.0005) continue;
      it.last = p;
      it.el.style.setProperty("--p", p.toFixed(4));
      if (it.el.id === "assemble") assemble(p);
      if (it.el.id === "how") howUpdate(p);
    }
  }
  function request() { if (!ticking) { ticking = true; requestAnimationFrame(frame); } }
  window.addEventListener("scroll", request, { passive: true });
  window.addEventListener("resize", function () { vh = window.innerHeight; prog.forEach(function (i) { i.last = -1; }); request(); });
  if (stage) assemble(0);
  frame();

  /* Marquees: double the (already duplicated) chip list so each half covers wide screens.
     The track moves by exactly half its width, so the loop stays seamless. */
  document.querySelectorAll(".track").forEach(function (t) {
    Array.prototype.slice.call(t.children).forEach(function (c) {
      var k = c.cloneNode(true); k.setAttribute("aria-hidden", "true"); t.appendChild(k);
    });
  });

  /* FAQ: only one open at a time feels calmer */
  var faqs = document.querySelectorAll(".faq details");
  faqs.forEach(function (d) {
    d.addEventListener("toggle", function () {
      if (d.open) faqs.forEach(function (o) { if (o !== d) o.open = false; });
    });
  });
})();
