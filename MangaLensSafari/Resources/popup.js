const ext = globalThis.browser ?? globalThis.chrome;

const LANGUAGES = [
  ["japanese", "日语"],
  ["korean", "韩语"],
  ["english", "英语"],
  ["automatic", "自动"],
];

const languagesEl = document.getElementById("languages");
const translateButton = document.getElementById("translate");
const showButton = document.getElementById("show");
const clearButton = document.getElementById("clear");
const openLink = document.getElementById("open-app");
const statusEl = document.getElementById("status");

let language = "japanese";
let busy = false;

for (const [value, title] of LANGUAGES) {
  const button = document.createElement("button");
  button.type = "button";
  button.textContent = title;
  button.dataset.language = value;
  button.addEventListener("click", () => selectLanguage(value));
  languagesEl.appendChild(button);
}

translateButton.addEventListener("click", translate);
showButton.addEventListener("click", showTranslations);
clearButton.addEventListener("click", clearTranslations);

restoreLanguage();

function selectLanguage(value) {
  language = value;
  paintLanguages();
  ext.storage.local.set({ sourceLanguage: value }).catch(() => {});
}

function paintLanguages() {
  for (const button of languagesEl.querySelectorAll("button")) {
    button.setAttribute("aria-pressed", button.dataset.language === language ? "true" : "false");
  }
}

async function restoreLanguage() {
  try {
    const stored = await ext.storage.local.get("sourceLanguage");
    if (stored && LANGUAGES.some(([value]) => value === stored.sourceLanguage)) {
      language = stored.sourceLanguage;
    }
  } catch (error) {
    language = "japanese";
  }
  paintLanguages();
}

async function translate() {
  if (busy) return;
  setBusy(true);
  openLink.classList.add("hidden");
  setStatus("正在截取这一屏…");
  try {
    let screenshot = null;
    if (ext.tabs && ext.tabs.captureVisibleTab) {
      try {
        screenshot = await ext.tabs.captureVisibleTab({ format: "jpeg", quality: 55 });
        screenshot = await shrinkShot(screenshot);
      } catch (error) {
        screenshot = null;
      }
    }
    const response = await ext.runtime.sendMessage({
      type: "translateViewport",
      language,
      screenshot,
    });
    if (!response || response.ok !== true) {
      setStatus((response && response.error) || "没有截到这一屏。");
      return;
    }
    if (response.openURL) openLink.href = response.openURL;
    openLink.classList.remove("hidden");
    const clipboard = response.channel === "pasteboard"
      ? "这次没有 App Group，画面放在本机剪贴板上。翻译完成前不要复制别的内容。"
      : "画面已交给 Manga Lens。";
    const opened = response.opened
      ? "如果系统问是否打开 App，点打开。"
      : "如果没有自动切过去，点下面的按钮，或自己打开 Manga Lens。";
    setStatus(clipboard + opened);
  } catch (error) {
    setStatus(errorText(error));
  } finally {
    setBusy(false);
  }
}

async function showTranslations() {
  if (busy) return;
  setBusy(true);
  setStatus("正在读取译文…");
  try {
    const response = await ext.runtime.sendMessage({ type: "showResult" });
    if (!response || response.ok !== true) {
      setStatus((response && response.error) || "还没有译文。");
      return;
    }
    const count = response.count || 0;
    setStatus("已在页面上标出 " + count + " 处。绑在图片上的会跟着走，没绑上的一滚动就藏起来。");
  } catch (error) {
    setStatus(errorText(error));
  } finally {
    setBusy(false);
  }
}

async function clearTranslations() {
  if (busy) return;
  setBusy(true);
  try {
    const response = await ext.runtime.sendMessage({ type: "clearOverlay" });
    setStatus(!response || response.ok === false
      ? ((response && response.error) || "没有清掉。")
      : "已清除这一页上的译文。");
  } catch (error) {
    setStatus(errorText(error));
  } finally {
    setBusy(false);
  }
}

function shrinkShot(dataURL) {
  if (!dataURL || dataURL.length < 1500000) return Promise.resolve(dataURL);
  return new Promise((resolve) => {
    const image = new Image();
    image.onload = () => {
      const scale = Math.min(1, 1400 / Math.max(image.width, image.height));
      const canvas = document.createElement("canvas");
      canvas.width = Math.max(1, Math.round(image.width * scale));
      canvas.height = Math.max(1, Math.round(image.height * scale));
      const context = canvas.getContext("2d");
      if (!context) {
        resolve(dataURL);
        return;
      }
      context.drawImage(image, 0, 0, canvas.width, canvas.height);
      resolve(canvas.toDataURL("image/jpeg", 0.6));
    };
    image.onerror = () => resolve(dataURL);
    image.src = dataURL;
  });
}

function setBusy(value) {
  busy = value;
  translateButton.disabled = value;
  showButton.disabled = value;
  clearButton.disabled = value;
}

function setStatus(text) {
  statusEl.textContent = text;
}

function errorText(error) {
  const text = String(error && error.message ? error.message : error);
  if (/receiving end|could not establish/i.test(text)) {
    return "扩展后台没有起来。把 Safari 完全关掉再打开，然后重试。";
  }
  return text || "没有完成。";
}
