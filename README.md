# claudex

> 讓 Claude Code 透過本機 [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) 使用 GPT 模型，
> 而且**不動到原本的 `claude` 指令**。新模型上架時自動採用，不寫死型號。
>
> *Run Claude Code against GPT models via a local CLIProxyAPI, without touching your existing `claude` setup. Auto-adopts newly released models.*

---

## 這是什麼

裝完之後你會有兩個指令：

| 指令 | 走哪裡 | 用什麼模型 |
|---|---|---|
| `claude` | Anthropic 官方，**完全不變** | 你原本的 Claude 模型 |
| `claudex` | 本機 CLIProxyAPI (`127.0.0.1:8317`) | 目前最新的 GPT 模型，**自動偵測** |

`claudex` 是一個 shell function，六個環境變數只在它執行的那一瞬間存在，不會外洩到你的 shell，也不會讓 `claude` 被永久導向 proxy。

## 需求

- **Claude Code** 已安裝（跨 session 溝通功能需要 2.1.228 以上，見〈跨 session 溝通〉）
- **Python 3**（`claudex` 用它解析模型清單；macOS/Linux 通常內建）
- **一個可用的 ChatGPT / Codex 訂閱帳號**（OAuth 登入用）
- macOS 需要 Homebrew；Linux 用官方安裝腳本；Windows 用 release 執行檔

---

## 安裝

### 步驟 1：安裝 CLIProxyAPI

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

到 [CLIProxyAPI releases](https://github.com/router-for-me/CLIProxyAPI/releases) 下載對應的執行檔，
或使用桌面 GUI [EasyCLIProxyAPI](https://github.com/router-for-me/EasyCLIProxyAPI)。

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

### 步驟 4：Codex OAuth 登入

```bash
cliproxyapi -codex-login
```

會自動開瀏覽器，登入你的 ChatGPT 帳號並授權。無瀏覽器的機器改用：

```bash
cliproxyapi -codex-device-login
```

憑證會存到 `~/.cli-proxy-api/`。**這個目錄不要分享、不要進版控。**

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

### 步驟 6：安裝 claudex

```bash
git clone https://github.com/<你的帳號>/claudex.git ~/.claudex
```

**zsh**（macOS 預設）— 加到 `~/.zshrc`：

```zsh
source ~/.claudex/claudex.sh
```

**bash** — 加到 `~/.bashrc`，內容同上。

**PowerShell** — 加到 `$PROFILE`：

```powershell
. $HOME\.claudex\claudex.ps1
```

然後 `source ~/.zshrc`（或開新視窗）。

---

## 使用

```bash
claudex                              # 自動用最新的 GPT 模型
claudex --models                     # 列出可用模型，標出會用哪一個
claudex --print "hello"              # 任何 Claude Code 參數都能照傳
claudex --model gpt-5.5              # 這次指定模型
CLAUDEX_MODEL=gpt-5.6-sol claudex    # 這次固定某個模型

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
| `CLAUDEX_MODEL` | *(空)* | 固定模型，設了就跳過自動偵測 |
| `CLAUDEX_FALLBACK_MODEL` | `gpt-5.6-sol` | proxy 連不上時的保底 |
| `CLAUDEX_EXCLUDE` | `image\|audio\|tts\|...` | 要忽略的模型 id 正規表達式 |
| `CLAUDEX_TOOL_SEARCH` | `true` | 見〈ENABLE_TOOL_SEARCH〉 |

模型的優先順序：`--model` > `CLAUDEX_MODEL` > 自動偵測 > `CLAUDEX_FALLBACK_MODEL`

---

## 驗證清單

```bash
# 1. 服務在跑、有在監聽
curl -s -o /dev/null -w "%{http_code}\n" -H "Authorization: Bearer sk-dummy" \
     http://127.0.0.1:8317/v1/models          # 期望 200

# 2. claudex 存在，而且是 function 不是 alias
type claudex                                   # 期望 "claudex is a shell function"

# 3. claude 沒有被改寫
type claude                                    # 期望 "claude is /path/to/claude"（不是 alias/function）

# 4. 環境變數沒有外洩到 shell（全部應為空）
echo "[$ANTHROPIC_BASE_URL][$ANTHROPIC_AUTH_TOKEN][$CLAUDE_CODE_SUBAGENT_MODEL]"

# 5. 端到端
claudex --print "Reply with exactly: OK"
```

---

## 疑難排解

**`claudex: cannot reach CLIProxyAPI`**
服務沒跑。`brew services restart cliproxyapi` / `systemctl --user restart cli-proxy-api`。

**模型清單是空的（`{"data":[],"object":"list"}`）**
OAuth 憑證過期或沒載入。重跑 `cliproxyapi -codex-login`，**然後重啟服務**。

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
- 這個 repo 不包含任何憑證。

---

## 移除

```bash
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
| Windows / PowerShell | ⚠️ `claudex.ps1` **未執行過**，僅照邏輯移植 |
| Docker | ⚠️ 指令引自官方文件，未實機驗證 |

歡迎回報，尤其是 Linux 和 Windows 的實際結果。
