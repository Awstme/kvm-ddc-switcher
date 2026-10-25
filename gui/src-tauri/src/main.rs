use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::thread;
use std::time::Duration;

use serde::Serialize;
use tauri::menu::{MenuBuilder, MenuItemBuilder};
use tauri::tray::TrayIconBuilder;
use tauri::{AppHandle, Manager, WindowEvent};

const LABEL: &str = "local.kvm.mac-autoswitch";

fn home() -> PathBuf {
    PathBuf::from(std::env::var("HOME").unwrap_or_default())
}

fn deploy_dir() -> PathBuf {
    home().join("Library/Application Support/kvm-ddc-switcher")
}

fn plist_path() -> PathBuf {
    home()
        .join("Library/LaunchAgents")
        .join(format!("{LABEL}.plist"))
}

fn config_path() -> PathBuf {
    deploy_dir().join("config.env")
}

fn log_path() -> PathBuf {
    deploy_dir().join("logs").join("kvm-auto-switch.log")
}

fn cmd_path() -> PathBuf {
    deploy_dir().join("command")
}

fn uid() -> String {
    Command::new("id")
        .arg("-u")
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_default()
}

fn daemon_pid() -> Option<u32> {
    let out = Command::new("launchctl").arg("list").output().ok()?;
    let text = String::from_utf8_lossy(&out.stdout);
    for line in text.lines() {
        let mut cols = line.split('\t');
        let pid = cols.next()?;
        let _status = cols.next();
        let label = cols.next()?;
        if label.trim() == LABEL {
            return pid.trim().parse::<u32>().ok();
        }
    }
    None
}

fn tail(path: &Path, max_lines: usize) -> Vec<String> {
    let text = fs::read_to_string(path).unwrap_or_default();
    let mut lines: Vec<String> = text.lines().map(|s| s.to_string()).collect();
    if lines.len() > max_lines {
        lines = lines.split_off(lines.len() - max_lines);
    }
    lines
}

// 显示器输入只能从守护进程日志推断（GUI 不直接读 DDC）
fn estimate_input(lines: &[String]) -> String {
    for line in lines.iter().rev() {
        if line.contains("KVM left Mac") || line.contains("manual command: switch-to-windows") {
            return "DP2（Windows）".into();
        }
        if line.contains("KVM returned to Mac") || line.contains("KVM initial state: present") {
            return "DP1（Mac）".into();
        }
        if line.contains("KVM initial state: absent") {
            return "DP2（Windows）".into();
        }
    }
    "未知".into()
}

fn bootout() {
    let _ = Command::new("launchctl")
        .arg("bootout")
        .arg(format!("gui/{}/{}", uid(), LABEL))
        .output();
}

fn bootstrap() -> Result<(), String> {
    let out = Command::new("launchctl")
        .arg("bootstrap")
        .arg(format!("gui/{}", uid()))
        .arg(plist_path())
        .output()
        .map_err(|e| e.to_string())?;
    if out.status.success() {
        Ok(())
    } else {
        Err(String::from_utf8_lossy(&out.stderr).trim().to_string())
    }
}

fn restart_daemon_inner() -> Result<(), String> {
    if !plist_path().exists() {
        return Err("开机自启未安装，无法重启守护进程（先打开「开机自启」）".into());
    }
    bootout();
    thread::sleep(Duration::from_millis(400));
    bootstrap()
}

fn find_repo_root() -> Option<PathBuf> {
    if let Ok(p) = std::env::var("KVM_DDC_ROOT") {
        let pb = PathBuf::from(p);
        if pb.join("macos/install-autostart.sh").exists() {
            return Some(pb);
        }
    }
    let exe = std::env::current_exe().ok()?;
    let mut dir = exe.parent()?.to_path_buf();
    for _ in 0..12 {
        if dir.join("macos/install-autostart.sh").exists() {
            return Some(dir);
        }
        dir = dir.parent()?.to_path_buf();
    }
    None
}

fn queue_switch() -> Result<String, String> {
    if daemon_pid().is_none() {
        return Err("守护进程未运行，无法执行手动切换".into());
    }
    fs::write(cmd_path(), "switch-to-windows")
        .map_err(|e| format!("写入命令文件失败：{e}"))?;
    Ok("已发送切换指令（约 0.5 秒内处理，见日志）".into())
}

#[derive(Serialize)]
struct Status {
    installed: bool,
    running: bool,
    pid: Option<u32>,
    deploy_dir: String,
    config_path: String,
    log_path: String,
    last_action: String,
    estimated_input: String,
}

#[tauri::command]
fn get_status() -> Result<Status, String> {
    let lines = tail(&log_path(), 120);
    let pid = daemon_pid();
    Ok(Status {
        installed: plist_path().exists(),
        running: pid.is_some(),
        pid,
        deploy_dir: deploy_dir().display().to_string(),
        config_path: config_path().display().to_string(),
        log_path: log_path().display().to_string(),
        last_action: lines.last().cloned().unwrap_or_default(),
        estimated_input: estimate_input(&lines),
    })
}

#[tauri::command]
fn get_log_tail(lines: usize) -> Result<String, String> {
    let n = lines.clamp(1, 500);
    Ok(tail(&log_path(), n).join("\n"))
}

#[tauri::command]
fn read_config() -> Result<String, String> {
    fs::read_to_string(config_path())
        .map_err(|e| format!("读取配置失败（{e}）：{}", config_path().display()))
}

#[tauri::command]
fn save_config(text: String) -> Result<String, String> {
    if text.trim().is_empty() {
        return Err("配置内容为空，未保存".into());
    }
    fs::write(config_path(), &text).map_err(|e| format!("写入失败：{e}"))?;
    restart_daemon_inner()?;
    Ok("已保存并重启守护进程".into())
}

#[tauri::command]
fn manual_switch() -> Result<String, String> {
    queue_switch()
}

#[tauri::command]
fn restart_daemon() -> Result<String, String> {
    restart_daemon_inner()?;
    Ok("守护进程已重启".into())
}

#[tauri::command]
fn set_autostart(enabled: bool) -> Result<String, String> {
    if enabled {
        if plist_path().exists() {
            bootout();
            thread::sleep(Duration::from_millis(400));
            bootstrap()?;
            return Ok("已重新加载开机自启".into());
        }
        let repo = find_repo_root()
            .ok_or("找不到仓库目录（可用环境变量 KVM_DDC_ROOT 指定仓库根）".to_string())?;
        let script = repo.join("macos").join("install-autostart.sh");
        let out = Command::new("/bin/zsh")
            .arg(&script)
            .output()
            .map_err(|e| e.to_string())?;
        if !out.status.success() {
            return Err(format!(
                "安装失败：{}",
                String::from_utf8_lossy(&out.stderr).trim()
            ));
        }
        Ok("已安装并启动开机自启".into())
    } else {
        bootout();
        let _ = fs::remove_file(plist_path());
        Ok("已关闭开机自启（部署副本与日志保留）".into())
    }
}

fn main() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![
            get_status,
            get_log_tail,
            read_config,
            save_config,
            manual_switch,
            restart_daemon,
            set_autostart
        ])
        .setup(|app| {
            let show = MenuItemBuilder::with_id("show", "打开窗口").build(app)?;
            let switch = MenuItemBuilder::with_id("switch", "手动切到 Windows").build(app)?;
            let quit = MenuItemBuilder::with_id("quit", "退出").build(app)?;
            let menu = MenuBuilder::new(app).items(&[&show, &switch, &quit]).build()?;

            // 菜单栏用单色模板图标（随系统明暗自适应），不用彩色 App 图标
            let tray_icon =
                tauri::image::Image::from_bytes(include_bytes!("../icons/tray-template.png"))?;
            TrayIconBuilder::with_id("main-tray")
                .tooltip("KVM DDC Switcher")
                .icon(tray_icon)
                .icon_as_template(true)
                .menu(&menu)
                .show_menu_on_left_click(true)
                .on_menu_event(|app: &AppHandle, event| match event.id.as_ref() {
                    "show" => {
                        if let Some(w) = app.get_webview_window("main") {
                            let _ = w.show();
                            let _ = w.set_focus();
                        }
                    }
                    "switch" => {
                        let _ = queue_switch();
                    }
                    "quit" => app.exit(0),
                    _ => {}
                })
                .build(app)?;
            Ok(())
        })
        .on_window_event(|window, event| {
            if let WindowEvent::CloseRequested { api, .. } = event {
                let _ = window.hide();
                api.prevent_close();
            }
        })
        .run(tauri::generate_context!())
        .expect("failed to run tauri app");
}
