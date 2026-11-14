# vpn-split

macOS 選單列與 CLI 小工具。讓清單中的網域／IPv4 網段使用已連線的 VPN，其餘 IPv4 流量保留原本路徑；也能編輯清單、控制 VPN 連線、查看出口 IP、延遲與下載速度。

不綁定 VPN 品牌，但**不是所有 VPN 的路由模式都相容**。VPN 控制與路由管理是兩件分開的事。

## 安裝

需求為 macOS、系統內建 Bash 3.2。選單列另需自行安裝 [SwiftBar](https://swiftbar.app/)。一般使用不需要 Python、Node 或套件管理器。

```bash
./install.command
~/.local/bin/vpn-split status
```

預設只安裝使用者 CLI 與 SwiftBar plugin，**不要求管理員權限、不連線 VPN、不改路由**。CLI 安裝於 `~/.local/bin/vpn-split`。若 shell 找不到指令，將 `~/.local/bin` 加入自己的 `PATH`，或直接使用完整路徑。

安裝沿用 SwiftBar 既有 PluginDirectory；未設定時使用 `~/.config/swiftbar`，需在 SwiftBar 選擇該資料夾。不會自動安裝 SwiftBar 或修改其既有設定。清單與 provider 設定位於 `~/.config/vpn-split/`，升級保留。

### 啟用實際分流

先連上相容的 VPN，執行唯讀檢查：

```bash
vpn-split add example.org
vpn-split routing-plan
```

確認路由與遠端復原方式後，再明確選擇安裝系統路由服務：

```bash
./install.command --routing
vpn-split doctor
```

這個選項透過 `sudo` 安裝 root-owned helper 與 launchd daemon。服務約每 5 秒檢查連線、清單與模式。安裝成功不代表路由已成功套用，請看 `doctor` 或選單中的實際套用狀態。

**遠端操作請先準備獨立的 SSH／螢幕共享復原連線。** VPN 客戶端、企業政策或其他網路工具可能持續改寫路由，衝突時本工具拒絕套用，不會強制覆寫。

## 使用

### VPN 連線方式

預設由使用者在既有 VPN 客戶端操作：

```bash
vpn-split config manual
```

若 VPN 服務可由 macOS `scutil --nc` 管理：

```bash
scutil --nc list
vpn-split config scutil 'My VPN'
vpn-split connect
vpn-split disconnect
```

客戶端若提供自己的 CLI，可用自己撰寫的兩個 executable script 接入：

```bash
vpn-split config hooks /absolute/path/connect-vpn /absolute/path/disconnect-vpn
vpn-split connect
vpn-split disconnect
```

Hook 不接收參數，各自負責單一連線／斷線操作。程式不保存密碼或 token，也不會執行 shell 字串、source provider 設定，或讓 root daemon 執行 hook。VPN 控制只能由一般使用者呼叫。各機器的設定不應提交到 Git。連線 provider 只決定如何啟動／斷線，分流的 tunnel 仍由路由偵測決定，不會藉由 provider 名稱挑選任意介面。

`connect` 成功表示控制命令成功返回，**不代表 VPN 已完成連線或分流**。狀態由實際網路與可用的 macOS service 狀態讀取，不會為了查狀態而呼叫連線 hook。

### 清單與模式

```bash
vpn-split add 'https://example.org/path' 192.0.2.10 198.51.100.0/24
vpn-split list
vpn-split remove example.org
vpn-split mode split
vpn-split mode full
```

`hosts.txt` 一行一項，支援註解、網域、IPv4 與 CIDR。範例使用保留網域／文件用網段，請換成自己的項目。可直接編輯檔案，或在選單列加入、移除及開啟清單。

- `split` 是清單目標經 VPN；`full` 是復原該 VPN 原本的兩條 `/1` 路由。
- `mode` 只寫入期望模式，必須有路由服務且實際套用成功才生效。
- 不支援萬用字元，加入 `example.org` 不會自動包含所有子網域。
- `/0` 與 VPN 的兩條原始 `/1` 路由不可作為清單項目。

### 網路診斷

```bash
vpn-split status
vpn-split check example.org
vpn-split health
vpn-split speedtest
vpn-split info
```

`status` 顯示目前測試路徑的出口 IP、介面與 TCP 連線時間。`check`／`health` 回報實際 HTTPS 連線的 remote IP、HTTP status、路由介面及完整請求耗時。HTTP 403 不會被解讀成「VPN 一定錯誤」。

`speedtest` 從 Cloudflare 下載 10 MB，回報實際遠端 IP 對應的介面與單次平均下載速度。HTTP／傳輸失敗及未下載完整內容不產生速度結果。它不是線路容量保證，也不是同時執行的雙路徑比較。

測試端點若實際走 VPN，才會顯示該次測得的 VPN 出口 IP。沒有可驗證的 VPN 測試路徑時顯示不可用，**不臨時改路由強迫測試，也不把目前路徑誤稱為直連**。

診斷會對外連線至 Cloudflare，健康檢查則連線至清單中的網域，不會上傳清單到其他服務。SwiftBar 每分鐘重新整理時會執行出口測試，測速僅由使用者手動觸發。

## 支援邊界

| 能力 | 範圍 |
| --- | --- |
| VPN 啟動／斷線 | manual、macOS `scutil --nc` 服務，或使用者的 executable hooks |
| 自動 IPv4 分流 | 同一 IPv4 point-to-point `utun` gateway／介面的兩條互補 `0.0.0.0/1` 與 `128.0.0.0/1` 路由，並保有單一非 VPN 的 default 路由 |
| 其他路由模式 | 不支援只有單一 default、沒有 peer gateway、僅 IPv6、Network Extension 強制全隧道等模式 |
| 相容性證據 | 自動化 mock 測試，尚未以真實 VPN 實機驗證，不能宣稱任一品牌已認證相容 |

這是**網域解析成 IP 後的 IP 路由分流**，不是依 HTTP hostname 分流：

1. 同一 IP 上的其他網站也可能走 VPN。DNS 回答改變後會重新建立目標路由，既有連線可能中斷。
2. IPv6 不在管理範圍，可能繞過 IPv4 清單。這不是 kill switch、DNS leak protection 或安全隔離工具。
3. VPN 專用 DNS 若必須經隧道才能到達，需把該 DNS 的 IPv4 加入清單。程式不改 DNS 設定，不繞過瀏覽器 DoH，無法解析目標時拒絕建立新的分流計畫。
4. 多 VPN、Tailscale 與其他路由工具共存時，狀態可能不明或有衝突。工具不把任意 `utun` 當作目標 VPN，也不管理 Tailscale。

## 路由安全與復原

服務只管理自己新增且仍精確匹配 gateway／介面的路由。既有同目標路由不會被搶占，衝突會拒絕套用。修改前先記錄 journal，部分失敗時復原；移除 host routes 前先復原原 VPN 的 `/1` 路由。中斷後保留 journal 以便恢復，不會憑空替其他 VPN 建立 default route。

系統檔案位置：

```text
/Library/PrivilegedHelperTools/local.vpn-split
/Library/LaunchDaemons/local.vpn-split.plist
/var/run/vpn-split/state
/var/log/vpn-split.log
```

root helper 是原始碼的 root-owned 副本，不從使用者可編輯的 repo 載入程式碼。服務只接受安裝時指定 UID 擁有的清單／模式檔，拒絕符號連結與其他使用者可寫的設定路徑。狀態中含路由 IP，但不保存 VPN 憑證。日誌及個人設定不進 repo。

遇到問題先在 VPN 客戶端斷線，再停用並移除路由服務：

```bash
vpn-split uninstall-routing
```

這會先停服務、復原仍屬於它的路由，再移除 helper。若復原衝突或失敗，保留狀態供檢查，不會當作成功清掉紀錄。不要手動刪除 state 來掩蓋尚未復原的路由。

## 升級與移除

```bash
./install.command             # 更新使用者 CLI 與選單
./install.command --routing   # 同時更新已選用的系統路由服務
./uninstall.command           # 移除使用者 CLI／選單，保留設定
./uninstall.command --routing # 先移除系統路由服務，再移除使用者檔案
```

原先的安裝包預設安裝 root daemon，本專案改為明確 opt-in。舊版 `/usr/local/bin/vpn-split` 不會被靜默刪除，使用 `command -v vpn-split` 確認呼叫新版本。如果曾安裝舊路由服務，請先在 VPN 已斷線時用原版移除流程卸載，再安裝新版服務。本專案不匯入任何原始工作網域。

## 開發與驗證

```bash
make check
```

開發檢查另需 Python 3 與 ShellCheck，執行工具本身不需要 Python。測試以隔離目錄及 mock 網路命令驗證 CLI、provider 操作、路由所有權／失敗復原及使用者安裝流程，不改開發機路由。另執行全部 shell 檔案的 Bash 語法檢查與 ShellCheck。GitHub Actions 在 macOS runner 執行同一入口。

尚未選定開源授權，因此未附 LICENSE。
