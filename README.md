# claudex

> 讓 Claude Code 透過本機 [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) 使用 GPT 模型，
> 而且**不動到原本的 `claude` 指令**。新模型上架時自動採用，不寫死型號。
>
> *Run Claude Code against GPT models via a local CLIProxyAPI, without touching your existing `claude` setup. Auto-adopts newly released models.*

---

## 這是什麼

裝完之後你會有五個指令：

| 指令 | 走哪裡 | 用什麼模型 |
|---|---|---|
| `claude` | Anthropic 官方，**完全不變** | 你原本的 Claude 模型 |
| `claudex` | 本機 CLIProxyAPI (`127.0.0.1:8317`) | 目前最新的 GPT 模型，**自動偵測** |
| `claudemini` | 同一個 CLIProxyAPI | 目前最新的 Gemini 模型，**自動偵測** |
| `claudeop` | OpenCode Go (`opencode.ai/zen/go/v1`) | 自動採用最新可用模型；Claude 直連，其他模型經 localhost bridge |
| `clauden` | 自架 VLLM (`127.0.0.1:8000`) | 自動採用 VLLM 目錄最新可用模型；一律經 localhost bridge |

`claudex`、`claudemini`、`claudeop` 和 `clauden` 都是 shell function。它們只在執行該次指令時注入 proxy 環境變數，不會外洩到你的 shell，也不會讓 `claude` 被永久導向 proxy。

## 需求

- **Claude Code** 已安裝（跨 session 溝通功能需要 2.1.228 以上，見〈跨 session 溝通〉）
- **Python 3**（`--models` 清單解析，以及 `claudeop` / `clauden` 的 localhost bridge 都需要；macOS/Linux 通常內建，Windows 需另外安裝並確認 `python` 在 PATH）
- 使用 `claudex`：一個可用的 ChatGPT / Codex 憑證（OAuth 登入用）
- 使用 `claudemini`：CLIProxyAPI 支援的 Gemini 憑證（Antigravity OAuth 或 API key）
- 使用 `claudeop`：OpenCode Go API key（從 [OpenCode auth](https://opencode.ai/auth) 建立）
- 使用 `clauden`：一台已在跑的 VLLM server（預設 `http://127.0.0.1:8000`，模型需支援 tool-calling）
- macOS 需要 Homebrew；Linux 用官方安裝腳本；Windows 用 release 執行檔＋桌面 GUI（見步驟 1），wrapper 使用 `*.ps1`

---

## 安裝

### 步驟 1：安裝 CLIProxyAPI

> **懶人包**：`install.sh --with-proxy`（macOS/Linux）或 `install.ps1 -WithProxy`（Windows）
> 會自動做掉步驟 1–3——偵測已在跑的 proxy（有就不碰）、裝執行檔、寫好本機限定設定、設成開機自動啟動。
> 登入（步驟 4）仍要手動，因為 OAuth 要開瀏覽器。

**macOS**

```bash
brew install cliproxyapi
```

> ⚠️ 網路上（含各家 AI）常說要先 `brew tap router-for-me/tap`。**那個 tap 不存在**，會 404。
> 這個 formula 已經在 homebrew-core 裡，直接 `brew install` 就好。

**Linux**（官方一鍵安裝）

```bash
curl -fsSL https://raw.githubusercontent.com/router-for-me/cliproxyapi-installer/refs/heads/master/cliproxyapi-installer | bash
```

Arch 系可改用 AUR：`yay -S cli-proxy-api-bin`

**Windows**

1. 到 [CLIProxyAPI releases](https://github.com/router-for-me/CLIProxyAPI/releases) 下載 `CLIProxyAPI_<版本>_windows_amd64.zip`，解壓出 `cli-proxy-api.exe` 放到固定目錄，例如 `C:\Tools\CLIProxyAPI\`（或跑 `install.ps1 -WithProxy` 自動下載到 `$HOME\.claudex\bin\`）。
2. 或使用桌面 GUI [EasyCLIProxyAPI](https://github.com/router-for-me/EasyCLIProxyAPI)，登入與改設定都在視窗裡完成。
3. 另外安裝 [Python 3](https://www.python.org/downloads/windows/)（安裝時勾選 **Add python.exe to PATH**，`claudeop` / `clauden` 的 bridge 需要它），以及 [Claude Code for Windows](https://code.claude.com/docs/en/windows-setup)（原生安裝或 WSL 二選一；本 repo 的 `*.ps1` 是給**原生 PowerShell** 用的）。
4. CLIProxyAPI 的設定檔與 `~/.cli-proxy-api/` 憑證目錄位置和 Linux 相同（`%USERPROFILE%\.cli-proxy-api`）；`host` 同樣要設成 `127.0.0.1`（見步驟 2）。

**Docker**（任何平台）

```bash
docker run --rm -p 8317:8317 \
  -v /path/to/your/config.yaml:/CLIProxyAPI/config.yaml \
  -v /path/to/your/auth-dir:/root/.cli-proxy-api \
  eceasy/cli-proxy-api:latest
```

### 步驟 2：設定 CLIProxyAPI

設定檔位置：

| 平台 | 路徑 |
|---|---|
| macOS (Apple Silicon) | `/opt/homebrew/etc/cliproxyapi.conf` |
| macOS (Intel) | `/usr/local/etc/cliproxyapi.conf` |
| Linux | 依安裝方式，通常 `~/.cli-proxy-api/config.yaml` |

**改之前先備份**，然後確認這三項：

```yaml
host: "127.0.0.1"     # 只綁本機。預設是 "" = 對外開放，請務必改掉
port: 8317
api-keys:
  - "sk-dummy"        # 本機用的假金鑰；claudex 預設就是找這個值
```

`auth-dir` 維持預設 `~/.cli-proxy-api` 即可。

### 步驟 3：啟動服務

```bash
# macOS
brew services start cliproxyapi

# Linux (systemd user service)
systemctl --user start cli-proxy-api

# 不想常駐，直接前景跑也可以
cliproxyapi
```

`--with-proxy` / `-WithProxy` 幫你設好的開機自啟方式（重開機後 proxy 自己起來並開始監聽 `127.0.0.1:8317`）：

| 平台 | 自啟機制 |
|---|---|
| macOS（brew） | `brew services`（launchd，登入自動啟動＋crash 自動重起） |
| macOS（無 brew，managed 安裝） | `~/Library/LaunchAgents/com.claudex.cliproxyapi.plist` |
| Linux（managed 安裝） | user systemd unit `claudex-proxy.service`（登入自動啟動；無登入開機也要跑再加 `sudo loginctl enable-linger <user>`） |
| Linux（沿用既有安裝） | 沿用該安裝自帶的 service；裝完記得 `enable` |
| Windows | 排程工作 `CLIProxyAPI`（登入自動啟動，失敗自動重試；經隱藏 PowerShell 背景執行，不佔視窗） |

登入（步驟 4）之後**一定要重啟服務**才會載入新憑證，各平台指令見步驟 4 末尾。

### 步驟 4：登入你要使用的模型服務

GPT 路線使用 Codex OAuth：

```bash
cliproxyapi -codex-login
```

會自動開瀏覽器，登入你的 ChatGPT 帳號並授權。無瀏覽器的機器改用：

```bash
cliproxyapi -codex-device-login
```

Gemini 路線使用 Antigravity OAuth：

```bash
cliproxyapi -antigravity-login
```

也可以在 CLIProxyAPI 設定檔放入 `gemini-api-key`，不用 OAuth。兩條路線可以同時設定；之後由 `claudex` 或 `claudemini` 選擇要走哪一條。

> **Windows 建議用登入小幫手**（repo 根目錄的 `login.ps1`；macOS/Linux 用 `login.sh`）：
> 它會先測試預設 callback port 能不能綁（Antigravity 的 `51121` 常落在 Windows 保留區段而失敗），
> 不能綁就自動換一個可用 port 再登入，登完自動重啟背景 proxy：
>
> ```powershell
> & $HOME\.claudex\login.ps1 codex          # GPT 路線
> & $HOME\.claudex\login.ps1 antigravity    # Gemini 路線
> & $HOME\.claudex\login.ps1 codex-device   # 無瀏覽器時用 device flow，不需要 callback port
> & $HOME\.claudex\login.ps1 opencode       # 輸入 OpenCode Go API key，驗證後永久存到使用者環境變數
> ```
>
> macOS/Linux：`~/.claudex/login.sh antigravity`。手動登入時記得加 `-config` 指到正確設定檔，
> 以及登入後重啟服務（見下方）。

OpenCode Go 不經過 CLIProxyAPI，直接到 [OpenCode auth](https://opencode.ai/auth) 登入並建立 API key。需要依 OpenCode 當前要求完成帳務設定；這把 key 只放在 shell 的 `CLAUDEOP_API_KEY`，不要寫進 repo。

憑證會存到 `~/.cli-proxy-api/`。OpenCode key 不會存到這裡；兩種憑證都不要分享、不要進版控。

**登入完成後一定要重啟服務**，否則它不會載入新憑證：

```bash
brew services restart cliproxyapi      # macOS
systemctl --user restart cli-proxy-api # Linux
```

### 步驟 5：確認 proxy 真的通了

```bash
# 應回 401（沒帶金鑰）
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8317/v1/models

# 應回 200，且列出 gpt-* 模型
curl -s -H "Authorization: Bearer sk-dummy" http://127.0.0.1:8317/v1/models
```

清單如果是**空的**，代表 OAuth 憑證沒載入 —— 回到步驟 4 重登再重啟。

### 步驟 6：放置 wrapper（macOS / Linux）

這個 repo 不需要 `npm install`、編譯或安裝 daemon。每條路線自成一個資料夾，裡面是 wrapper（`.sh`）和該路線需要的 bridge（`.py`，會在需要時暫時啟動在 localhost）：

```
claudex/          # GPT 路線（CLIProxyAPI）
  claudex.sh
claudemini/       # Gemini 路線（同一個 CLIProxyAPI）
  claudemini.sh
claudeop/         # OpenCode Go 路線
  claudeop.sh
  claudeop_bridge.py
clauden/          # 自架 VLLM 路線
  clauden.sh
  clauden_bridge.py
```

你可以選一種方式取得檔案：

**方式 A：一鍵安裝（推薦）** — 複製檔案並自動把 `source` 加到你的 shell 設定，冪等（跑多次不會重複），改前會先備份：

```bash
curl -fsSL https://raw.githubusercontent.com/jason79461385/claudex/main/install.sh | bash
```

要連 CLIProxyAPI 一起裝好（含開機自啟），加 `--with-proxy`（會先偵測 8317 是否已有服務，有就不動）：

```bash
curl -fsSL https://raw.githubusercontent.com/jason79461385/claudex/main/install.sh | bash -s -- --with-proxy
```

常用選項（先 clone 再跑也可以：`git clone ... ~/.claudex && ~/.claudex/install.sh ...`）：

```bash
~/.claudex/install.sh --routes claudex,clauden   # 只裝這兩條路線
~/.claudex/install.sh --rc ~/.bashrc             # 寫到 bashrc 而非自動偵測
~/.claudex/install.sh --uninstall                # 移除設定（檔案保留）
~/.claudex/install.sh --uninstall --remove-files # 移除設定並刪除檔案
```

**方式 B：clone repo**

```bash
git clone https://github.com/jason79461385/claudex.git ~/.claudex
```

這樣 `~/.claudex` 底下的結構和上面完全一樣，更新時只要 `git pull`。然後手動加下面的 `source` 行。

**方式 C：repo 已經在本機**

```bash
mkdir -p ~/.claudex/claudex ~/.claudex/claudemini ~/.claudex/claudeop ~/.claudex/clauden
cp /path/to/claudex/claudex/claudex.sh ~/.claudex/claudex/
cp /path/to/claudex/claudemini/claudemini.sh ~/.claudex/claudemini/
cp /path/to/claudex/claudeop/claudeop.sh ~/.claudex/claudeop/
cp /path/to/claudex/claudeop/claudeop_bridge.py ~/.claudex/claudeop/
cp /path/to/claudex/clauden/clauden.sh ~/.claudex/clauden/
cp /path/to/claudex/clauden/clauden_bridge.py ~/.claudex/clauden/
```

**zsh**（macOS 預設）— 加到 `~/.zshrc`：

```zsh
source ~/.claudex/claudex/claudex.sh
source ~/.claudex/claudemini/claudemini.sh
source ~/.claudex/claudeop/claudeop.sh
source ~/.claudex/clauden/clauden.sh
```

只需要某一條路線時，可以只 source 對應檔案。**bash** — 將相同內容加到 `~/.bashrc`。

然後 `source ~/.zshrc` / `source ~/.bashrc`。wrapper 不需要 `chmod +x`，因為它是用 `source` 載入的。

### 步驟 6（Windows）：放置 wrapper（PowerShell）

Windows 用的是各資料夾裡的 `*.ps1`（共四個），bridge 照樣是同一個 `*.py`（需 Python 3；`claudeop_bridge.py` 在 `claudeop/` 裡，`clauden_bridge.py` 在 `clauden/` 裡，**不要拆散**，否則 wrapper 找不到 bridge）：

**方式 A：一鍵安裝（推薦）** — 複製檔案並自動改 `$PROFILE`，冪等，改前會先備份：

```powershell
git clone https://github.com/jason79461385/claudex.git $HOME\.claudex
& $HOME\.claudex\install.ps1
```

要連 CLIProxyAPI 一起裝好（含登入自動啟動），改跑 `& $HOME\.claudex\install.ps1 -WithProxy`（會先偵測 8317 是否已有服務，有就不動）。

若 ExecutionPolicy 擋下腳本，改用 `powershell -ExecutionPolicy Bypass -File $HOME\.claudex\install.ps1`。常用選項：`-Routes claudex,clauden` 只裝部分路線；`-Uninstall` / `-Uninstall -RemoveFiles` 移除設定。

**方式 B：手動放置**

```powershell
# 1. 取得檔案（選一種）
git clone https://github.com/jason79461385/claudex.git $HOME\.claudex
#  或手動複製，目錄結構照抄：
#  claudex\claudex.ps1 / claudemini\claudemini.ps1 /
#  claudeop\claudeop.ps1 + claudeop\claudeop_bridge.py /
#  clauden\clauden.ps1 + clauden\clauden_bridge.py
#  到 $HOME\.claudex\ 底下

# 2. 允許執行本機腳本（只需做一次，以管理員身分跑）：
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser

# 3. 把下面四行加到 $PROFILE（先跑 notepad $PROFILE，不存在會自動建立）：
. $HOME\.claudex\claudex\claudex.ps1
. $HOME\.claudex\claudemini\claudemini.ps1
. $HOME\.claudex\claudeop\claudeop.ps1
. $HOME\.claudex\clauden\clauden.ps1
```

只需要某一條路線時，可以只 dot-source 對應檔案。然後關掉重開一個 PowerShell 視窗。

> `claudeop` / `clauden` 在 Windows 上一樣會自動啟動 localhost bridge（`python claudeop_bridge.py ...`），結束後自動停止；`python` 必須在 PATH 裡，否則會報 bridge 啟動失敗。

---

## 使用

```bash
claudex                              # 自動用最新的 GPT 模型
claudex --models                     # 列出可用的 GPT 對話模型
claudex --models-all                 # 列出 proxy 上的全部模型，含被濾掉的
claudex --print "hello"              # 任何 Claude Code 參數都能照傳

claudemini                           # 自動用最新的 Gemini 模型
claudemini --models                  # 列出可用的 Gemini 對話模型
claudemini --models-all              # 連同非 Gemini 模型一起列出
claudemini --print "hello"           # 使用 Gemini route 執行

printf 'OpenCode Go API key: '
read -r -s CLAUDEOP_API_KEY
printf '\n'
claudeop                             # 自動使用 catalogue 中最新的可用模型
claudeop --models                    # 列出可自動選用的模型（依新到舊）
claudeop --models-all                # 連同 CLAUDEOP_EXCLUDE 排除的模型
claudeop --print "hello"             # 使用 OpenCode Go 執行
claudeop --model deepseek-v4-pro --print "hello"  # 指定模型，經 localhost bridge 執行
unset CLAUDEOP_API_KEY               # 不留在目前 shell

clauden                              # 自動使用 VLLM 目錄中最新的可用模型
clauden --models                     # 列出 VLLM 服務的模型
clauden --model my-qwen3 --print "hello"  # 指定 VLLM 模型，經 localhost bridge 執行

claude                               # 原本的 Claude Code，完全不受影響
```

`claudex --models` 輸出長這樣：

```
  gpt-5.6-luna             2026-07-10   <- claudex uses this
  gpt-5.6-sol              2026-07-10
  gpt-5.6-terra            2026-07-10
  gpt-5.5                  2026-04-23
  gpt-5.4-mini             2026-03-17
```

`--models-all` 會多列出被 `CLAUDEX_EXCLUDE` 濾掉的項目（繪圖、review 之類的端點，
不能拿來跑 session）：

```
  codex-auto-review        2026-04-23   (not a chat model, skipped)
  gpt-image-2              2024-01-01   (not a chat model, skipped)
```

### `claudemini` 的特別行為

`claudemini` 和 `claudex` 共用同一個 proxy，但不會把「全站最新模型」誤選成 GPT：

1. 先查 `/v1/models`。
2. 只保留符合 `CLAUDEMINI_INCLUDE` 的 id（預設 `gemini|antigravity`）。
3. 再排除 image、audio、review 等非對話模型。
4. Gemini route 常回傳 `created=0`，所以改用模型 id 裡的版本號排序；無版本號的 id 放最後。

Gemini 的 function-calling 目前可能無法驗證 `query.where` 的 tuple schema，因此 `claudemini` 預設把 `Artifact` 從送出的工具宣告中移除。這不是把權限藏起來而已，而是避免整個請求在產生文字前就因 schema 400；確認你的 Gemini route 已支援 `prefixItems` 後，才設定：

```bash
export CLAUDEMINI_DISALLOW=""
```

### `claudeop` 的特別行為

`claudeop` 會依模型選擇 route：

- `claude-*`：直接使用 OpenCode Go 的 Anthropic Messages endpoint。
- 非 `claude-*` 模型（包含 DeepSeek V4）：自動啟動 `claudeop_bridge.py`，在 `127.0.0.1` 把 Claude Code 的 Messages request 轉成 OpenCode 的 Chat Completions request。
- `claudeop --models`：列出 OpenCode Go 回傳、可自動選用的模型，依 `created` 由新到舊排序，並標示 direct 或 local bridge；`--models-all` 會把 `CLAUDEOP_EXCLUDE` 排除的模型也列出。
- 沒有指定模型時，每次啟動都重新抓 `/models`，選最新可用模型；若 catalogue 抓不到，改用 `CLAUDEOP_FALLBACK_MODEL`。
- `CLAUDEOP_MODEL` 或顯式 `--model` 可固定／覆寫自動選擇；`CLAUDEOP_SUBAGENT_MODEL` 留空時跟隨實際選中的主模型。
- bridge 只在該次 `claudeop` 執行期間存在，結束後自動停止；API key 由 bridge 直接轉送給 OpenCode，不寫入 command line。
- `CLAUDEOP_TOOL_SEARCH` 預設是 `false`。確認 route 會轉送 `tool_reference` 後，才改成 `true`。
- 非 Claude 模型會以已知的 Claude Code model label 啟動，bridge 再把 upstream model 固定回你選的 OpenCode model；因此不會在本地 model catalog 階段因 `deepseek-*` 而拒絕。
- bridge 也提供 localhost 的 `GET /v1/models` 與 `GET /v1/models/<id>` probe，避免 Claude Code 在送出 Messages 前把相容 model 誤判成不可用。
- `CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT=1` 仍會啟用，避免 Claude Code 對這個相容 label 錯誤套用 context window 限制；實際 context 上限仍由 OpenCode 模型決定。

這條路線不經過本機 CLIProxyAPI，也不會使用 Codex 或 Gemini OAuth。非 Claude 模型的工具呼叫、串流和文字回覆由 bridge 轉換；圖片、文件與 OpenCode 尚未支援的特殊工具仍可能不相容。

### `clauden` 的特別行為（自架 VLLM）

`clauden` 讓 Claude Code 跑在你自己的 VLLM server 上。VLLM 只懂 OpenAI Chat Completions，所以**每個 session 都經過** `clauden_bridge.py`（localhost，結束後自動停止）：

- `clauden --models`：列出 VLLM `/v1/models` 回傳的模型，依 `created` 由新到舊排序；`--models-all` 會把 `CLAUDEN_EXCLUDE` 排除的模型也列出。
- 沒有指定模型時，每次啟動都重新抓 `/v1/models`，選最新可用模型；抓不到時改用 `CLAUDEN_MODEL` / `CLAUDEN_FALLBACK_MODEL`。
- subagent 共用同一個 session bridge，所以永遠跟主模型用同一個 VLLM 模型。
- 被 serve 的模型需要 tool-calling 支援（例如 `vllm serve ... --enable-auto-tool-choice --tool-call-parser <parser>`），否則 Claude Code 的工具（Read/Edit/Bash…）無法運作。
- reasoning 模型的 `reasoning_content` 會被丟掉，只保留最終答案文字。
- VLLM server 本身不由這個 repo 啟動；先確認 `curl http://127.0.0.1:8000/v1/models` 有回應再跑 `clauden`。

```bash
# 啟動 VLLM（範例，模型與參數依你的 GPU 調整）
vllm serve Qwen/Qwen3-8B --enable-auto-tool-choice --tool-call-parser hermes

# 之後在另一個終端機
clauden --models
clauden --print "Reply with exactly: OK"
```

### 換模型

三種範圍，看你要影響多久：

```bash
# 只有這一次
claudex --model gpt-5.6-sol

# 只有這個終端機視窗（之後每次 claudex 都用它）
export CLAUDEX_MODEL=gpt-5.6-sol
claudex

# 永久（加到 ~/.zshrc，放在 source claudex.sh 之前或之後都可以）
echo 'export CLAUDEX_MODEL=gpt-5.6-sol' >> ~/.zshrc && source ~/.zshrc

# 取消固定，改回自動選最新
unset CLAUDEX_MODEL          # 若已寫進 ~/.zshrc，要把那行刪掉
```

`claudemini` 使用同樣的三種方式，只是變數和模型名改成 Gemini：

```bash
# 只有這一次
claudemini --model gemini-3.1-pro-preview

# 固定目前終端機視窗
export CLAUDEMINI_MODEL=gemini-3.1-pro-preview
claudemini

# 取消固定，恢復自動挑選
unset CLAUDEMINI_MODEL
```

`claudeop` 同樣支援單次或固定模型：

```bash
# 只有這一次
claudeop --model claude-sonnet-4-6

# 固定目前終端機視窗
export CLAUDEOP_MODEL=claude-sonnet-4-6
claudeop

# 取消固定，恢復自動選最新可用模型
unset CLAUDEOP_MODEL
```

`clauden` 支援同樣的三種方式（變數改成 `CLAUDEN_*`）：

```bash
# 只有這一次
clauden --model my-qwen3

# 固定目前終端機視窗
export CLAUDEN_MODEL=my-qwen3
clauden

# 取消固定，恢復自動選最新可用模型
unset CLAUDEN_MODEL
```

DeepSeek V4 會自動走 bridge：

```bash
claudeop --model deepseek-v4-pro --print "Reply with exactly: OK"
export CLAUDEOP_MODEL=deepseek-v4-pro
export CLAUDEOP_SUBAGENT_MODEL=deepseek-v4-pro
claudeop
```

顯式傳入的 `--model` / `-m` 優先於環境變數；可用的實際 id 先用 `claudex --models`、`claudemini --models` 或 `claudeop --models` 查。

### 在 session 內換模型

直接打 `/model` 會發現**選單裡只有一個項目** —— 這是正常的。Claude Code 沒辦法列舉自訂 proxy 上
有哪些模型，所以選單只知道你當下這個。

改用**帶參數**的形式就可以（實測有效）：

```
/model gpt-5.6-sol
```

之後 `/status` 就會顯示 `Model: gpt-5.6-sol`。型號用 `claudex --models` 查。

兩個注意事項：

- 只影響**當下這個 session**，`claudex` 下次啟動仍是自動選最新。要改預設請用上面的 `CLAUDEX_MODEL`。
- `/model` 只換主模型。subagent 用的是啟動時 `CLAUDE_CODE_SUBAGENT_MODEL` 的值，不會跟著變。

驗證現在會用哪個：`claudex --models` 看 `<- claudex uses this` 標在誰身上。

---

## 自動選模是怎麼運作的

每次執行 `claudex`（沒指定模型時）：

1. 查 `http://127.0.0.1:8317/v1/models`
2. 濾掉非對話模型 —— 比對 `CLAUDEX_EXCLUDE` 這個正規表達式（image / audio / embed / review …）
3. 依 `created` 時間戳**由新到舊**排序
4. **同一天發布的多個模型，取名稱字母序第一個**（讓結果可重現，不受 API 回傳順序影響）
5. 取第一名啟動

所以未來 OpenAI 上架 `gpt-5.7-*`，`claudex` 下次執行就會自動採用，**你不用改任何設定**。

### ⚠️ 這個規則的已知弱點

排序依據是**發布日期，不是能力**。如果哪天上架一個新的小模型（例如 `gpt-5.7-mini`），它會因為日期最新而被選中。

兩個徵兆：`claudex --models` 最上面換人了，或是回答品質突然變差。處理方式：

```bash
export CLAUDEX_MODEL=gpt-5.6-sol   # 加到 ~/.zshrc，固定住
```

另外，同日發布的變體（實測 `gpt-5.6-terra` / `sol` / `luna` 的 `created` 完全相同）純靠字母序決定，
這是刻意的取捨 —— 換取可重現性，代價是選到哪個變體不代表哪個比較好。

---

## 可調參數

全部都是選填，寫在 `source claudex.sh` **之前**：

| 變數 | 預設 | 用途 |
|---|---|---|
| `CLAUDEX_BASE_URL` | `http://127.0.0.1:8317` | proxy 位址 |
| `CLAUDEX_API_KEY` | `sk-dummy` | proxy 金鑰，要和 `api-keys` 一致 |
| `CLAUDEX_MODEL` | *(空)* | 固定主模型，設了就跳過自動偵測 |
| `CLAUDEX_SUBAGENT_MODEL` | `gpt-5.6-terra` | 所有新建 subagent 使用的模型；不隨主模型自動切換 |
| `CLAUDEX_MAX_CONTEXT_TOKENS` | *(空)* | 已確認的模型 context window；設定後傳給 Claude Code 作為 auto-compaction 門檻 |
| `CLAUDEX_FALLBACK_MODEL` | `gpt-5.6-sol` | proxy 連不上時的保底 |
| `CLAUDEX_EXCLUDE` | `image\|audio\|tts\|...` | 要忽略的模型 id 正規表達式 |
| `CLAUDEX_TOOL_SEARCH` | `true` | 見〈ENABLE_TOOL_SEARCH〉 |

`claudemini` 使用另一組前綴，避免兩條路線互相污染：

| 變數 | 預設 | 用途 |
|---|---|---|
| `CLAUDEMINI_BASE_URL` | `http://127.0.0.1:8317` | proxy 位址 |
| `CLAUDEMINI_API_KEY` | `sk-dummy` | proxy 金鑰 |
| `CLAUDEMINI_MODEL` | *(空)* | 固定 Gemini 主模型 |
| `CLAUDEMINI_SUBAGENT_MODEL` | *(空，跟隨主模型)* | subagent 模型 |
| `CLAUDEMINI_SUBAGENT_FORCE` | `1` | 強制 subagent 留在 Gemini route |
| `CLAUDEMINI_MAX_CONTEXT_TOKENS` | `1000000` | 傳給 Claude Code 的 context / auto-compaction 門檻 |
| `CLAUDEMINI_FALLBACK_MODEL` | `gemini-3.1-pro-preview` | proxy 連不上或沒有可選模型時的保底 |
| `CLAUDEMINI_INCLUDE` | `gemini\|antigravity` | 必須符合的模型 id 正規表達式 |
| `CLAUDEMINI_EXCLUDE` | `image\|audio\|...` | 要忽略的模型 id 正規表達式 |
| `CLAUDEMINI_TOOL_SEARCH` | `true` | 是否啟用延後工具搜尋 |
| `CLAUDEMINI_DISALLOW` | `Artifact` | 不送出的工具名稱；Gemini schema 修好後可設空字串 |

`claudeop` 使用 OpenCode Go 的專用前綴：

| 變數 | 預設 | 用途 |
|---|---|---|
| `CLAUDEOP_BASE_URL` | `https://opencode.ai/zen/go/v1` | OpenCode Go API 位址 |
| `CLAUDEOP_API_KEY` | *(必填)* | OpenCode Go API key |
| `CLAUDEOP_MODEL` | *(空)* | 固定主模型；留空時每次自動選 catalogue 最新可用模型 |
| `CLAUDEOP_FALLBACK_MODEL` | `deepseek-v4-pro` | catalogue 無法取得時的保底模型 |
| `CLAUDEOP_EXCLUDE` | `image\|audio\|tts\|...` | 自動選模時要忽略的模型 id 正規表達式 |
| `CLAUDEOP_SUBAGENT_MODEL` | *(空，跟隨主模型)* | subagent 模型 |
| `CLAUDEOP_MAX_CONTEXT_TOKENS` | *(空)* | 已確認的 context / auto-compaction 門檻 |
| `CLAUDEOP_TOOL_SEARCH` | `false` | 是否啟用延後工具搜尋；需 route 支援 `tool_reference` |
| `CLAUDEOP_BRIDGE_SCRIPT` | `claudeop_bridge.py` 同目錄 | 非 Claude 模型的轉接程式路徑 |
| `CLAUDEOP_BRIDGE_PORT` | `0` | localhost bridge port；`0` 代表自動挑選 |
| `CLAUDEOP_FRONTEND_MODEL` | `claude-sonnet-5` | Claude Code 本地相容 label；bridge 仍使用你選的 OpenCode model |
| `CLAUDEOP_DEBUG` | *(空)* | 設為 `1` 時顯示 bridge HTTP diagnostics；不顯示 request body 或 key |

`clauden`（自架 VLLM）使用另一組前綴：

| 變數 | 預設 | 用途 |
|---|---|---|
| `CLAUDEN_BASE_URL` | `http://127.0.0.1:8000` | VLLM 位址，可含或不含 `/v1` |
| `CLAUDEN_API_KEY` | *(空)* | VLLM API key；留空代表不送 auth header |
| `CLAUDEN_MODEL` | *(空)* | 固定主模型；留空時每次自動選目錄最新可用模型 |
| `CLAUDEN_FALLBACK_MODEL` | *(空，跟隨 `CLAUDEN_MODEL`)* | 目錄抓不到時的保底模型 |
| `CLAUDEN_EXCLUDE` | `image\|audio\|tts\|...` | 自動選模時要忽略的模型 id 正規表達式 |
| `CLAUDEN_MAX_CONTEXT_TOKENS` | *(空)* | 已確認的 context / auto-compaction 門檻 |
| `CLAUDEN_TOOL_SEARCH` | `true` | 是否啟用延後工具搜尋 |
| `CLAUDEN_BRIDGE_SCRIPT` | `clauden_bridge.py` 同目錄 | 轉接程式路徑 |
| `CLAUDEN_BRIDGE_PORT` | `0` | localhost bridge port；`0` 代表自動挑選 |
| `CLAUDEN_FRONTEND_MODEL` | `claude-sonnet-5` | Claude Code 本地相容 label；bridge 仍使用你選的 VLLM model |
| `CLAUDEN_DEBUG` | *(空)* | 設為 `1` 時顯示 bridge 錯誤（不含 request 資料） |

`claudeop` 模型的優先順序：`--model` > `CLAUDEOP_MODEL` > 自動偵測 > `CLAUDEOP_FALLBACK_MODEL`

`claudemini` 的優先順序：`--model` > `CLAUDEMINI_MODEL` > 自動偵測 > `CLAUDEMINI_FALLBACK_MODEL`

若已確認目前透過 proxy 使用的模型與 route 都支援 1M context，可在 `source` 前設定：

```zsh
export CLAUDEX_MAX_CONTEXT_TOKENS=1000000
export CLAUDEX_SUBAGENT_MODEL=gpt-5.6-terra  # 預設值，明列以固定行為
source ~/.claudex/claudex/claudex.sh
```

`CLAUDEX_MAX_CONTEXT_TOKENS` 只告訴 Claude Code 何時進行 auto-compaction，並不會提高 proxy 或 upstream endpoint 的真實請求上限。若小型 diff 的全新 session 仍收到 `Prompt is too long`，應視為該 route／proxy adapter 的實際限制與宣稱的 1M 不一致，而非提高這個值。

Gemini 路線預設已設成 1M；若實際 route 不支援，請改成已確認的值，並把 subagent 留在同一個 Gemini 模型：

```zsh
export CLAUDEMINI_MAX_CONTEXT_TOKENS=1000000
export CLAUDEMINI_SUBAGENT_MODEL=gemini-3.1-pro-preview
source ~/.claudex/claudemini/claudemini.sh
```

`CLAUDEMINI_MAX_CONTEXT_TOKENS` 同樣只影響 auto-compaction，不會替 upstream 增加真實 context 上限。

OpenCode Go 的實際上限依模型與帳戶而定；確認後才設定：

```zsh
# 只有拿到 OpenCode Go 實際上限後才填入：
# export CLAUDEOP_MAX_CONTEXT_TOKENS=<confirmed-value>
export CLAUDEOP_SUBAGENT_MODEL=deepseek-v4-pro
source ~/.claudex/claudeop/claudeop.sh
```

這個值只影響 auto-compaction，不會替 OpenCode Go 增加真實 context 上限。

---

## 驗證清單

```bash
# 1. 服務在跑、有在監聽
curl -s -o /dev/null -w "%{http_code}\n" -H "Authorization: Bearer sk-dummy" \
     http://127.0.0.1:8317/v1/models          # 期望 200

# 2. wrappers 存在，而且是 function 不是 alias
type claudex                                   # 期望 "claudex is a shell function"
type claudemini                                # 期望 "claudemini is a shell function"
type claudeop                                  # 期望 "claudeop is a shell function"

# 3. claude 沒有被改寫
type claude                                    # 期望 "claude is /path/to/claude"（不是 alias/function）

# 4. 環境變數沒有外洩到 shell（全部應為空）
echo "[$ANTHROPIC_BASE_URL][$ANTHROPIC_AUTH_TOKEN][$CLAUDE_CODE_SUBAGENT_MODEL]"

# 5. 端到端：依你設定的 route 各跑一次
claudex --print "Reply with exactly: OK"
claudemini --print "Reply with exactly: OK"

# 6. OpenCode Go（先設定 CLAUDEOP_API_KEY）
claudeop --models                       # 應列出 catalogue 模型
claudeop --print "Reply with exactly: OK"  # Claude direct route
claudeop --model deepseek-v4-pro --print "Reply with exactly: OK"  # bridge route

# 7. 自架 VLLM（先啟動 vllm serve）
clauden --models                        # 應列出 VLLM 服務的模型
clauden --print "Reply with exactly: OK"
```

Windows（PowerShell）的對應檢查：

```powershell
# wrappers 存在，而且是 function
Get-Command claudex, claudemini, claudeop, clauden
# 環境變數沒有外洩（應無輸出）
Get-ChildItem Env:ANTHROPIC_BASE_URL, Env:ANTHROPIC_AUTH_TOKEN -ErrorAction SilentlyContinue
# 端到端
claudex --print "Reply with exactly: OK"
clauden --print "Reply with exactly: OK"
```

---

## 疑難排解

**`claudex: cannot reach CLIProxyAPI`**
服務沒跑。`brew services restart cliproxyapi` / `systemctl --user restart cli-proxy-api`。

**`claudeop: set CLAUDEOP_API_KEY to your OpenCode Go API key`**
目前 shell 沒有 OpenCode Go key。先設定 `CLAUDEOP_API_KEY`；不要把它寫進 repo 或貼到聊天視窗。

**`claudeop` 回 401 / `Missing API key`**
確認使用的是 OpenCode Go key，不是 Anthropic key；確認 `CLAUDEOP_BASE_URL` 保持 `https://opencode.ai/zen/go/v1`。Go route 使用 `Authorization: Bearer`；wrapper 會在該次子程序內清空 `ANTHROPIC_API_KEY`、改用 `ANTHROPIC_AUTH_TOKEN`，不需要登出 claude.ai。

**`claudeop` 回 model 不存在或模型清單沒有該 id**
先跑 `claudeop --models`，再用清單中實際出現的 id 設定 `CLAUDEOP_MODEL` 或傳 `--model`。OpenCode Go 的模型清單會變動，不要自行拼接模型名稱。

**仍看到 `[claude-code:unrecognized_model]` 或只有 generic model error**
重新執行 `source ~/.claudex/claudeop/claudeop.sh`。非 Claude route 會用 `CLAUDEOP_FRONTEND_MODEL`（預設 `claude-sonnet-5`）作為 Claude Code 的本地 label，再由 bridge 轉送實際 OpenCode model。若仍失敗，可用 `CLAUDEOP_DEBUG=1 claudeop --model deepseek-v4-pro --print "Reply with exactly: OK"` 顯示不含 request body/key 的 bridge diagnostics。

**`claudeop: bridge script not found` / `clauden: bridge script not found`**
把 `claudeop/` 整個資料夾（`claudeop.sh` + `claudeop_bridge.py`）或 `clauden/` 整個資料夾（`clauden.sh` + `clauden_bridge.py`）一起複製，不要拆散；或設定 `CLAUDEOP_BRIDGE_SCRIPT` / `CLAUDEN_BRIDGE_SCRIPT` 為絕對路徑。Windows 上還要確認 `python` 在 PATH 裡（`python --version` 有回應）。

**`clauden: cannot reach VLLM` / `clauden: no model selected`**
VLLM 沒跑或位址錯誤。先跑 `curl http://127.0.0.1:8000/v1/models` 確認；位址不同時設定 `CLAUDEN_BASE_URL`。離線固定模型時設定 `CLAUDEN_MODEL`。

**`clauden` 工具呼叫沒反應**
被 serve 的模型不支援 tool-calling。啟動 VLLM 時加上 `--enable-auto-tool-choice --tool-call-parser <parser>`（parser 依模型家族選擇，例如 hermes、llama3_json、qwen3 等）。

**DeepSeek 回 400、工具呼叫失敗或輸出格式不完整**
目前 bridge 轉換文字、圖片 URL/base64、工具宣告、tool call 和串流；Anthropic 特殊 blocks、文件、部分 server tools 仍可能不相容。先用簡單文字任務確認 route，再逐步加入工具。

**模型清單是空的（`{"data":[],"object":"list"}`）**
OAuth 憑證過期或沒載入。重跑對應的登入指令（GPT 用 `cliproxyapi -codex-login`，Gemini 用 `cliproxyapi -antigravity-login`），**然後重啟服務**。

**`claudemini: the proxy serves no Gemini model.`**
Proxy 本身有回應，但 `/v1/models` 沒有符合 `CLAUDEMINI_INCLUDE` 的 id。先跑 `claudemini --models-all` 看實際 id；若還沒登入，執行 `cliproxyapi -antigravity-login` 後重啟服務。

**登入時 `failed to start callback server: listen tcp :51121: bind: ... forbidden`**
Windows 把 `51121`（Antigravity 預設 callback port）劃進保留區段（Hyper-V/WSL 留的，可用
`netsh interface ipv4 show excludedportrange` 確認）。不要硬改系統保留區，用登入小幫手自動換 port：
`& $HOME\.claudex\login.ps1 antigravity`（macOS/Linux 用 `~/.claudex/login.sh antigravity`）；
手動則加 `-oauth-callback-port <可用port>`（Codex 預設是 `1455`，`codex-device-login` 不需要 callback port）。

**Gemini route 回 400，錯誤提到 `query.where` / `prefixItems`**
這是目前 Gemini function-calling validator 不接受 Artifact 工具 schema。保留預設的 `CLAUDEMINI_DISALLOW=Artifact`；只有確認 route 已支援該 schema 後才設成空字串。

**`"gpt-5.x-xxx" is not a model this version of Claude Code recognizes`**
正常，不影響運作。Claude Code 不認識這個型號，所以假設 200k 上下文並據此 auto-compact。
若該模型視窗更大，可設 `CLAUDE_CODE_MAX_CONTEXT_TOKENS`，或在 `modelOverrides` 設定裡對應。

**`claude.ai connectors are disabled because ANTHROPIC_API_KEY or another auth source is set`**
預期行為，因為設了 `ANTHROPIC_AUTH_TOKEN`。**只影響 `claudex` 的 session**，`claude` 不受影響。

**Claude Code 更新之後壞掉了**
`claudex` 用的六個變數裡，`ANTHROPIC_BASE_URL` / `ANTHROPIC_AUTH_TOKEN` 是公開穩定的，
其餘四個是**未公開的內部旗標**，改名或移除時會**靜默失效**（不報錯）。更新後自檢：

```bash
for f in ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_SUBAGENT_MODEL \
         CLAUDE_CODE_ALWAYS_ENABLE_EFFORT CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY ENABLE_TOOL_SEARCH; do
  n=$(strings "$(readlink -f "$(command -v claude)")" | grep -c "$f")
  [ "$n" -gt 0 ] && echo "  OK   $f" || echo "  GONE $f  <- 需要調整"
done
```

（`claude` 本身的執行檔是 symlink，自動更新只會重指 symlink，所以 `claudex` 不會因為更新而斷掉。）

---

## ENABLE_TOOL_SEARCH

`true` 時 Claude Code 不會把全部工具定義塞進 prompt，改成讓模型需要時再搜尋載入。

實測（gpt-5.6-luna，`claude --print --output-format json`）：

| 情境 | `false` | `true` |
|---|---|---|
| 不需要延後載入工具的回合 | 22,678 tokens | **12,550** |
| 需要延後載入工具的回合 | **23,396** / 2 turns | 26,544 / 3 turns |

同時觀察到 `cache_read` 與 `cache_creation` 都是 **0** —— 從 Claude Code 的帳面看不到 prompt cache
命中（上游可能有自己的自動快取，但無法從這裡確認）。沒有快取代表每個回合都重送完整 prompt，
所以基準 prompt 小 10k 的效益會**逐回合累積**。

預設用 `true`。若你在 `claudex` 裡大量使用 MCP 工具，或發現它「該用某個工具卻沒用」，改成
`export CLAUDEX_TOOL_SEARCH=false`。

---

## 跨 session 溝通

`claudex` 開的 session 可以和一般 `claude` session 互傳訊息 —— session 註冊表
（`~/.claude/sessions/<pid>.json`）是純本機檔案，**不含 API key、base URL 或 model**，
所以 proxy 對它完全透明。

**前提：雙方都要 Claude Code 2.1.228 以上。** 收訊靠 unix socket
（`/tmp/cc-socks/<pid>.sock`），實測 2.1.226 以下的 session 不會建立它，只能發不能收。

用法 —— 開兩個終端機，各自取名：

```bash
CLAUDE_CODE_SESSION_NAME=main   claude     # 指揮方
CLAUDE_CODE_SESSION_NAME=worker claudex    # 工作方
```

然後在 `main` 那邊用自然語言下指令（不是打工具名稱）：

> 用 ListAgents 看看有哪些 session
>
> 傳訊息給 worker，請它跑測試並把結果回傳給我

**實測到的坑**：GPT 模型在「回覆時該填什麼位址」上容易出錯（實測連續三次填錯 `to`）。
派工時在訊息裡直接加一句可大幅改善：

> 回覆時，把這則訊息的 `from` 屬性原封不動當作你的 `to`。

建議固定由 `claude` 當指揮方（主動權留在 Claude 這一側），`claudex` 當工作方。

---

## 安全注意

- `sk-dummy` 只是本機用的佔位金鑰。**前提是 `host` 設成 `127.0.0.1`** —— 預設值 `""` 會綁所有介面，
  等於把你的 ChatGPT 帳號開放給同網段任何人使用。
- `~/.cli-proxy-api/` 裡是真的 OAuth 憑證。不要進版控、不要分享、不要貼到聊天視窗。
- `CLAUDEOP_API_KEY` 是 OpenCode Go 的付費 API key。不要進版控、不要分享、不要貼到聊天視窗；wrapper 只在單次 `claudeop` 執行時注入。
- 這個 repo 不包含任何憑證。

---

## 移除

用安裝器移除最乾淨（會刪掉管理的設定區塊，`--remove-files` / `-RemoveFiles` 才會刪檔案）：

```bash
~/.claudex/install.sh --uninstall --remove-files   # macOS / Linux
```

```powershell
& $HOME\.claudex\install.ps1 -Uninstall -RemoveFiles  # Windows
```

或手動：
# 1. 從 ~/.zshrc / ~/.bashrc / $PROFILE 移除那行 source
# 2. 停掉服務
brew services stop cliproxyapi        # macOS
systemctl --user stop cli-proxy-api   # Linux
# 3. 移除 CLIProxyAPI 與憑證
brew uninstall cliproxyapi
rm -rf ~/.cli-proxy-api
```

`claude` 不受任何影響。

---

## 測試狀態

| 項目 | 狀態 |
|---|---|
| macOS 26.4 / arm64 / zsh | ✅ 完整實測 |
| bash | ✅ `claudex.sh` 全功能實測（與 zsh 行為一致） |
| Linux | ⚠️ 安裝指令引自官方文件，未實機驗證 |
| Windows / PowerShell | ✅ 五個 `*.ps1` 皆在 pwsh 7 下實測載入、`--models` 邏輯與安裝/移除流程；⚠️ 未在真正的 Windows 機器上跑過 |
| `install.sh --with-proxy` | ✅ macOS 沙盒實測三條路徑：已在跑（不碰）、brew 安裝＋自啟、無 brew 下載＋launchd＋自啟（含端到端 `/v1/models` 回應）；Linux 用 stub 驗證下載＋config＋systemd unit 產生 |
| `install.ps1 -WithProxy` | ✅ pwsh 7 下實測：已在跑（不碰）、本地 zip 安裝＋config 產生＋無 scheduler 時優雅降級；⚠️ 真 Windows 上的下載＋排程註冊未實機驗證 |
| Docker | ⚠️ 指令引自官方文件，未實機驗證 |
| OpenCode Go / `claudeop` | ⚠️ `/v1/models` endpoint 已確認可連線；需要使用者 API key 才能做端到端驗證 |
| 自架 VLLM / `clauden` | ⚠️ bridge 邏輯與 `claudeop` 同源；需使用者自備 VLLM server 驗證 |

歡迎回報，尤其是 Linux、Windows 和 OpenCode Go 的實際結果。
