const { invoke } = window.__TAURI__.core;

const $ = (id) => document.getElementById(id);
let configLoaded = false;

function showMsg(text, ok = true) {
  const el = $("msg");
  el.textContent = text;
  el.classList.remove("hidden");
  el.classList.toggle("error", !ok);
  clearTimeout(showMsg._t);
  showMsg._t = setTimeout(() => el.classList.add("hidden"), 4000);
}

async function refreshStatus() {
  try {
    const s = await invoke("get_status");
    const badge = $("badge-daemon");
    if (s.running) {
      badge.textContent = "守护进程：运行中" + (s.pid ? " (pid " + s.pid + ")" : "");
      badge.className = "badge ok";
    } else if (s.installed) {
      badge.textContent = "守护进程：已安装，未运行";
      badge.className = "badge warn";
    } else {
      badge.textContent = "守护进程：未安装";
      badge.className = "badge error";
    }
    $("badge-input").textContent = "预计输入源：" + s.estimated_input;
    $("last-action").textContent = "最近动作：" + (s.last_action || "（暂无）");
    $("chk-autostart").checked = s.installed;
    $("paths").textContent =
      "部署目录：" + s.deploy_dir + "\n配置：" + s.config_path + "\n日志：" + s.log_path;
    if (!configLoaded) await loadConfig();
  } catch (e) {
    showMsg("状态读取失败：" + e, false);
  }
}

async function refreshLog() {
  if (!$("chk-tail").checked) return;
  try {
    const text = await invoke("get_log_tail", { lines: 200 });
    const el = $("log");
    el.textContent = text || "（暂无日志）";
    el.scrollTop = el.scrollHeight;
  } catch (_) {
    /* 状态轮询会提示错误，这里静默 */
  }
}

async function loadConfig() {
  try {
    $("config").value = await invoke("read_config");
    configLoaded = true;
  } catch (e) {
    $("config").value = "";
    $("config").placeholder = String(e);
  }
}

$("btn-switch").onclick = async () => {
  try {
    showMsg(await invoke("manual_switch"));
  } catch (e) {
    showMsg(String(e), false);
  }
  setTimeout(refreshLog, 800);
};

$("btn-restart").onclick = async () => {
  try {
    showMsg(await invoke("restart_daemon"));
  } catch (e) {
    showMsg(String(e), false);
  }
  setTimeout(refreshStatus, 900);
};

$("btn-log-refresh").onclick = refreshLog;

$("btn-config-save").onclick = async () => {
  try {
    showMsg(await invoke("save_config", { text: $("config").value }));
  } catch (e) {
    showMsg(String(e), false);
  }
  setTimeout(() => {
    refreshStatus();
    refreshLog();
  }, 900);
};

$("chk-autostart").onchange = async (ev) => {
  const enabled = ev.target.checked;
  try {
    showMsg(await invoke("set_autostart", { enabled }));
  } catch (e) {
    showMsg(String(e), false);
  }
  setTimeout(refreshStatus, 900);
};

refreshStatus();
refreshLog();
setInterval(refreshStatus, 2000);
setInterval(refreshLog, 2000);
