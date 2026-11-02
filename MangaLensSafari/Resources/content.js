// Runs in the page's isolated world. It does nothing until the toolbar asks.
// document_idle on purpose: iOS document_start is unreliable, and we only need
// the DOM after the user taps "翻译可视区域".
(function () {
  const ext = globalThis.browser ?? globalThis.chrome;
  if (!ext || globalThis.__mangaLensContent) return;
  globalThis.__mangaLensContent = true;

  let sequence = 1;
  let overlay = null;

  ext.runtime.onMessage.addListener((message, _sender, sendResponse) => {
    if (!message || typeof message.type !== "string") return;
    try {
      if (message.type === "collect") sendResponse(collect());
      else if (message.type === "collectPieces") sendResponse(collectPieces());
      else if (message.type === "show") sendResponse(show(message));
      else if (message.type === "clear") {
        clearOverlay();
        sendResponse({ ok: true });
      }
    } catch (error) {
      sendResponse({ ok: false, error: "页面脚本出错了。" });
    }
  });

  document.addEventListener("scroll", schedulePosition, true);
  window.addEventListener("resize", schedulePosition);
  if (window.visualViewport) {
    window.visualViewport.addEventListener("scroll", schedulePosition);
    window.visualViewport.addEventListener("resize", schedulePosition);
  }

  function schedulePosition() {
    if (!overlay) return;
    requestAnimationFrame(positionChips);
  }

  function collect() {
    return {
      ok: true,
      pageURL: location.href,
      title: document.title || "",
      cssWidth: window.innerWidth,
      cssHeight: window.innerHeight,
      dpr: window.devicePixelRatio || 1,
      anchors: collectAnchors(),
    };
  }

  function collectAnchors() {
    const anchors = [];
    const images = document.querySelectorAll("img, canvas");
    for (const element of images) {
      if (anchors.length >= 12) break;
      if (!element.isConnected) continue;
      const rect = element.getBoundingClientRect();
      if (!largeEnough(rect, 48, 48)) continue;
      anchors.push(anchor(stamp(element), rect, element.tagName === "CANVAS" ? "canvas" : "image"));
    }

    const blocks = document.querySelectorAll("p, li, h1, h2, h3, td, figcaption");
    let textCount = 0;
    for (const element of blocks) {
      if (textCount >= 24) break;
      if (!element.isConnected || element.querySelector("img, canvas")) continue;
      const text = (element.innerText || "").trim();
      if (text.length < 1 || text.length > 40) continue;
      const rect = element.getBoundingClientRect();
      if (!largeEnough(rect, 12, 10) || rect.height > 160) continue;
      anchors.push(anchor(stamp(element), rect, "text"));
      textCount += 1;
    }
    return anchors;
  }

  function collectPieces() {
    const pieces = [];
    const images = document.querySelectorAll("img, canvas");
    for (const element of images) {
      if (pieces.length >= 6) break;
      if (!element.isConnected) continue;
      const rect = element.getBoundingClientRect();
      if (!largeEnough(rect, 48, 48)) continue;
      const box = anchor(stamp(element), rect, "image");
      if (element.tagName === "CANVAS") {
        const dataURL = rasterize(element, element.width, element.height);
        if (dataURL) pieces.push({ ...box, dataURL });
        continue;
      }
      const dataURL = rasterize(element, element.naturalWidth, element.naturalHeight);
      if (dataURL) {
        pieces.push({ ...box, dataURL });
        continue;
      }
      const src = element.currentSrc || element.src || "";
      if (/^https?:/i.test(src)) pieces.push({ ...box, src });
    }

    if (pieces.length < 6) {
      const blocks = document.querySelectorAll("div, a, figure");
      let seen = 0;
      for (const element of blocks) {
        if (pieces.length >= 6 || seen >= 80) break;
        seen += 1;
        if (!element.isConnected || element.querySelector("img")) continue;
        const rect = element.getBoundingClientRect();
        if (!largeEnough(rect, 80, 80)) continue;
        const src = backgroundURL(element);
        if (!src) continue;
        pieces.push({ ...anchor(stamp(element), rect, "image"), src });
      }
    }
    return { ok: true, pieces };
  }

  function show(message) {
    if (message.pageURL && !samePage(message.pageURL, location.href)) {
      return { ok: false, error: "译文属于另一个网页。回到那一页，或重新翻译这一屏。" };
    }
    const count = paint(message.lines, message.anchors);
    if (!count) return { ok: false, error: "没有可以标在页面上的译文。" };
    const visible = overlay.chips.filter((chip) => chip.el.style.display !== "none").length;
    if (!visible) {
      clearOverlay();
      return { ok: false, error: "这一页已经重新排过，译文对不上。请再点一次「翻译可视区域」。" };
    }
    return { ok: true, count: visible };
  }

  function paint(lines, anchors) {
    clearOverlay();
    const host = document.createElement("div");
    host.id = "manga-lens-overlay-host";
    host.style.cssText = [
      "position:fixed",
      "left:0",
      "top:0",
      "width:100%",
      "height:100%",
      "z-index:2147483647",
      "pointer-events:none",
    ].join(";");
    const root = host.attachShadow({ mode: "open" });
    const style = document.createElement("style");
    style.textContent = [
      ".chip{",
      "position:absolute;",
      "box-sizing:border-box;",
      "display:flex;",
      "align-items:center;",
      "justify-content:center;",
      "overflow:hidden;",
      "color:#000;",
      "background:rgba(255,255,255,0.9);",
      "border:0.5px solid rgba(0,0,0,0.35);",
      "border-radius:3px;",
      "font-family:-apple-system,BlinkMacSystemFont,sans-serif;",
      "font-weight:600;",
      "line-height:1.15;",
      "text-align:center;",
      "pointer-events:none;",
      "padding:0 2px;",
      "}",
    ].join("");
    root.appendChild(style);

    const chips = [];
    const list = Array.isArray(lines) ? lines : [];
    const anchorList = Array.isArray(anchors) ? anchors : [];
    for (const line of list) {
      const text = String(line.text || "").trim();
      const box = {
        x: Number(line.x),
        y: Number(line.y),
        w: Number(line.w),
        h: Number(line.h),
      };
      if (!text || !finiteBox(box)) continue;
      const chip = document.createElement("div");
      chip.className = "chip";
      chip.textContent = text;
      root.appendChild(chip);
      chips.push({ el: chip, box, binding: bindLine(box, anchorList) });
    }
    if (!chips.length) return 0;
    document.documentElement.appendChild(host);
    overlay = {
      host,
      chips,
      anchors: Array.isArray(anchors) ? anchors : [],
      scrollX: window.scrollX,
      scrollY: window.scrollY,
    };
    positionChips();
    return chips.length;
  }

  function positionChips() {
    if (!overlay) return;
    const hint = layoutHint(overlay.anchors || []);
    const windowMoved = Math.hypot(window.scrollX - overlay.scrollX, window.scrollY - overlay.scrollY) > 24;
    // Fixed coordinates are only trustworthy while the captured elements are
    // still where we measured them. Nested scrollers move those elements
    // without changing window.scrollY.
    const fixedStale = windowMoved || hint.seen === 0 || hint.moved;
    for (const chip of overlay.chips) {
      const binding = chip.binding;
      if (binding) {
        const host = document.querySelector('[data-manga-lens-id="' + binding.id + '"]');
        if (host && host.isConnected) {
          const rect = host.getBoundingClientRect();
          place(
            chip.el,
            rect.left + binding.nx * rect.width,
            rect.top + binding.ny * rect.height,
            binding.nw * rect.width,
            binding.nh * rect.height
          );
          continue;
        }
      }
      if (fixedStale) {
        chip.el.style.display = "none";
        continue;
      }
      place(chip.el, chip.box.x, chip.box.y, chip.box.w, chip.box.h);
    }
  }

  function layoutHint(anchors) {
    let seen = 0;
    let moved = false;
    for (const anchor of anchors) {
      if (!anchor || !anchor.id) continue;
      const host = document.querySelector('[data-manga-lens-id="' + anchor.id + '"]');
      if (!host || !host.isConnected) continue;
      seen += 1;
      const rect = host.getBoundingClientRect();
      if (Math.hypot(rect.left - Number(anchor.x), rect.top - Number(anchor.y)) > 24) moved = true;
    }
    return { seen, moved };
  }

  function clearOverlay() {
    if (overlay && overlay.host && overlay.host.parentNode) {
      overlay.host.parentNode.removeChild(overlay.host);
    }
    const leftover = document.getElementById("manga-lens-overlay-host");
    if (leftover && leftover.parentNode) leftover.parentNode.removeChild(leftover);
    overlay = null;
  }

  function bindLine(line, anchors) {
    let best = null;
    let bestScore = 0;
    const area = Math.max(line.w * line.h, 1);
    for (const anchor of anchors) {
      if (!anchor || !anchor.id || !finiteBox(anchor)) continue;
      const overlap = intersectionArea(line, anchor);
      if (overlap > bestScore) {
        bestScore = overlap;
        best = anchor;
      }
    }
    if (!best || bestScore < area * 0.45 || best.w < 1 || best.h < 1) return null;
    return {
      id: String(best.id),
      nx: (line.x - best.x) / best.w,
      ny: (line.y - best.y) / best.h,
      nw: line.w / best.w,
      nh: line.h / best.h,
    };
  }

  function intersectionArea(a, b) {
    const width = Math.min(a.x + a.w, b.x + b.w) - Math.max(a.x, b.x);
    const height = Math.min(a.y + a.h, b.y + b.h) - Math.max(a.y, b.y);
    if (width <= 0 || height <= 0) return 0;
    return width * height;
  }

  function place(element, left, top, width, height) {
    if (!(width >= 8) || !(height >= 8)) {
      element.style.display = "none";
      return;
    }
    element.style.display = "flex";
    element.style.left = left + "px";
    element.style.top = top + "px";
    element.style.width = width + "px";
    element.style.height = height + "px";
    element.style.fontSize = Math.max(9, Math.min(height * 0.62, 22)) + "px";
  }

  function stamp(element) {
    const existing = element.getAttribute("data-manga-lens-id");
    if (existing && /^ml-\d+$/.test(existing)) return existing;
    const id = "ml-" + sequence;
    sequence += 1;
    element.setAttribute("data-manga-lens-id", id);
    return id;
  }

  function anchor(id, rect, kind) {
    return { id, x: rect.left, y: rect.top, w: rect.width, h: rect.height, kind };
  }

  function largeEnough(rect, minWidth, minHeight) {
    if (!rect || rect.width < minWidth || rect.height < minHeight) return false;
    const overlapW = Math.min(rect.right, window.innerWidth) - Math.max(rect.left, 0);
    const overlapH = Math.min(rect.bottom, window.innerHeight) - Math.max(rect.top, 0);
    return overlapW > 12 && overlapH > 12;
  }

  function finiteBox(box) {
    return [box.x, box.y, box.w, box.h].every((value) => Number.isFinite(value));
  }

  function rasterize(source, sourceWidth, sourceHeight) {
    const width = sourceWidth || 0;
    const height = sourceHeight || 0;
    if (width < 2 || height < 2) return null;
    const scale = Math.min(1, 1200 / Math.max(width, height));
    const canvas = document.createElement("canvas");
    canvas.width = Math.max(1, Math.round(width * scale));
    canvas.height = Math.max(1, Math.round(height * scale));
    const context = canvas.getContext("2d");
    if (!context) return null;
    try {
      context.drawImage(source, 0, 0, canvas.width, canvas.height);
      const url = canvas.toDataURL("image/jpeg", 0.7);
      if (!url || url.length < 32 || url.length > 1800000) return null;
      return url;
    } catch (error) {
      return null;
    }
  }

  function backgroundURL(element) {
    const value = getComputedStyle(element).backgroundImage || "";
    const match = /url\(["']?(https?:[^"')]+)["']?\)/i.exec(value);
    return match ? match[1] : null;
  }

  function samePage(stored, current) {
    try {
      const left = new URL(stored);
      const right = new URL(current);
      if (left.protocol !== "http:" && left.protocol !== "https:") return false;
      left.hash = "";
      right.hash = "";
      return left.origin === right.origin && left.pathname === right.pathname && left.search === right.search;
    } catch (error) {
      return false;
    }
  }
})();
