// Non-persistent service worker. Listeners stay at the top level so Safari
// can wake the worker. Content scripts cannot call native messaging; this
// file is the only one that does.
const ext = globalThis.browser ?? globalThis.chrome;

const MAX_SHOT_CHARS = 3200000;

ext.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (!message || typeof message.type !== "string") return false;
  const task = route(message);
  if (!task) return false;
  task.then(sendResponse, (error) => {
    sendResponse({ ok: false, error: explain(error) });
  });
  return true;
});

function route(message) {
  if (message.type === "translateViewport") return translateViewport(message.language, message.screenshot);
  if (message.type === "showResult") return showResult();
  if (message.type === "clearOverlay") return clearOverlay();
  return null;
}

async function translateViewport(language, providedShot) {
  const tab = await activeTab();
  const geometry = await askContent(tab.id, { type: "collect" });
  if (!geometry || geometry.ok === false) {
    throw new Error((geometry && geometry.error) || "读不到这个页面。");
  }
  const pageURL = geometry.pageURL || tab.url || "";
  if (!/^https?:/i.test(pageURL)) {
    throw new Error("not-web");
  }

  // The popup captures while the tap is still the user gesture. If that
  // picture is missing, try again from here, then fall back to <img> bytes.
  let screenshot = null;
  if (typeof providedShot === "string" && providedShot.indexOf("data:image") === 0) {
    screenshot = providedShot;
  } else {
    try {
      screenshot = await captureShot();
    } catch (error) {
      screenshot = null;
    }
  }
  if (screenshot && screenshot.length > MAX_SHOT_CHARS) {
    try {
      screenshot = await shrinkDataURL(screenshot, 1400, 0.6);
    } catch (error) {
      screenshot = null;
    }
  }

  let pieces = null;
  if (!screenshot || screenshot.length > MAX_SHOT_CHARS) {
    screenshot = null;
    const collected = await askContent(tab.id, { type: "collectPieces" });
    const rawPieces = collected && Array.isArray(collected.pieces) ? collected.pieces : [];
    pieces = await fillPieces(rawPieces);
    if (!pieces.length) throw new Error("pieces-empty");
  }

  const payload = {
    type: "store",
    language: language || "japanese",
    pageURL,
    title: geometry.title || "",
    cssWidth: geometry.cssWidth,
    cssHeight: geometry.cssHeight,
    dpr: geometry.dpr || 1,
    anchors: geometry.anchors || [],
  };
  if (screenshot) payload.screenshot = screenshot;
  if (pieces && pieces.length) payload.pieces = pieces;
  const response = await native(payload);
  if (!response || response.ok !== true) {
    throw new Error((response && response.error) || "没有把画面交给 Manga Lens。");
  }
  try {
    await ext.storage.local.set({
      sourceLanguage: language || "japanese",
      lastJobID: response.jobID,
    });
  } catch (error) {
    // The capture is already stored. Remembering the language can fail quietly.
  }
  return response;
}

async function showResult() {
  const tab = await activeTab();
  const result = await native({ type: "readResult" });
  if (!result || result.ok !== true) {
    throw new Error((result && result.error) || "还没有译文。");
  }
  if (!result.lines || !result.lines.length) {
    throw new Error(result.message || "这一屏没有译出文字。");
  }
  const shown = await askContent(tab.id, {
    type: "show",
    pageURL: result.pageURL,
    lines: result.lines,
    anchors: result.anchors || [],
  });
  if (!shown || shown.ok === false) {
    throw new Error((shown && shown.error) || "页面上没有放上译文。");
  }
  return { ok: true, count: shown.count, message: result.message || "" };
}

async function clearOverlay() {
  const tab = await activeTab();
  await askContent(tab.id, { type: "clear" });
  return { ok: true };
}

async function activeTab() {
  const tabs = await ext.tabs.query({ active: true, currentWindow: true });
  if (!tabs || !tabs.length || tabs[0].id == null) {
    throw new Error("no-tab");
  }
  return tabs[0];
}

async function askContent(tabId, message) {
  try {
    return await ext.tabs.sendMessage(tabId, message);
  } catch (error) {
    if (!ext.scripting || !ext.scripting.executeScript) throw error;
    await ext.scripting.executeScript({ target: { tabId }, files: ["content.js"] });
    return ext.tabs.sendMessage(tabId, message);
  }
}

async function captureShot() {
  if (!ext.tabs || !ext.tabs.captureVisibleTab) {
    throw new Error("no-capture");
  }
  const shot = await ext.tabs.captureVisibleTab({ format: "jpeg", quality: 55 });
  if (!shot || typeof shot !== "string" || shot.indexOf("data:image") !== 0) {
    throw new Error("empty-capture");
  }
  return shot;
}

async function fillPieces(pieces) {
  const filled = [];
  for (const piece of pieces) {
    if (filled.length >= 6) break;
    if (piece.dataURL) {
      filled.push({
        x: piece.x,
        y: piece.y,
        w: piece.w,
        h: piece.h,
        dataURL: piece.dataURL,
      });
      continue;
    }
    if (!piece.src || !/^https?:/i.test(piece.src)) continue;
    try {
      const dataURL = await fetchAsDataURL(piece.src);
      if (!dataURL) continue;
      filled.push({ x: piece.x, y: piece.y, w: piece.w, h: piece.h, dataURL });
    } catch (error) {
      // This image is hotlink-protected or tainted. Skip it.
    }
  }
  return filled;
}

async function fetchAsDataURL(url) {
  const response = await fetch(url, { credentials: "include", cache: "force-cache" });
  if (!response.ok) return null;
  const blob = await response.blob();
  if (!blob || blob.size < 32 || blob.size > 7000000) return null;
  try {
    return await shrinkBlob(blob, 1200, 0.7);
  } catch (error) {
    return blobToDataURL(blob);
  }
}

async function shrinkDataURL(dataURL, maxEdge, quality) {
  const blob = await (await fetch(dataURL)).blob();
  return shrinkBlob(blob, maxEdge, quality);
}

async function shrinkBlob(blob, maxEdge, quality) {
  if (typeof createImageBitmap !== "function" || typeof OffscreenCanvas !== "function") {
    return blobToDataURL(blob);
  }
  const bitmap = await createImageBitmap(blob);
  try {
    const scale = Math.min(1, maxEdge / Math.max(bitmap.width, bitmap.height));
    const width = Math.max(1, Math.round(bitmap.width * Math.min(scale, 1)));
    const height = Math.max(1, Math.round(bitmap.height * Math.min(scale, 1)));
    const canvas = new OffscreenCanvas(width, height);
    const context = canvas.getContext("2d");
    if (!context) return blobToDataURL(blob);
    context.drawImage(bitmap, 0, 0, width, height);
    const out = await canvas.convertToBlob({ type: "image/jpeg", quality });
    return blobToDataURL(out);
  } finally {
    bitmap.close();
  }
}

function blobToDataURL(blob) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result || ""));
    reader.onerror = () => reject(reader.error || new Error("read"));
    reader.readAsDataURL(blob);
  });
}

function native(message) {
  const pending = ext.runtime.sendNativeMessage("com.julyanxu.MangaLens", message);
  if (!pending || typeof pending.then !== "function") {
    return Promise.reject(new Error("当前 Safari 不能把画面交给 Manga Lens。"));
  }
  return withTimeout(pending, 20000);
}

function withTimeout(pending, ms) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("timeout")), ms);
    pending.then(
      (value) => {
        clearTimeout(timer);
        resolve(value);
      },
      (error) => {
        clearTimeout(timer);
        reject(error);
      }
    );
  });
}

function explain(error) {
  const text = String(error && error.message ? error.message : error);
  if (text === "not-web" || text === "no-tab") {
    return "这个页面不能翻译。请打开普通的 http 或 https 网页。";
  }
  if (text === "pieces-empty") {
    return "没有截到这一屏，页面里的图也读不出来。若漫画画在跨域 canvas 上，需要系统截图；这次它没有返回画面。";
  }
  if (text === "timeout") {
    return "等太久了。回到 Safari 再点一次。";
  }
  if (/permission|access|host|not allowed|receiving end/i.test(text)) {
    return "Safari 还没允许 Manga Lens 看这个网站。到 设置 → Safari → 扩展 → Manga Lens，把网站权限改成允许，然后重新打开这个网页。";
  }
  return text;
}
