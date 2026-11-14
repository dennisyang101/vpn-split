# vpn-split

macOS 選單列與 CLI 工具。讓指定網域、IPv4 或網段走 VPN，其餘 IPv4 流量走原本網路。支援清單編輯、VPN 控制、出口 IP、延遲與下載測速，不綁定特定 VPN 品牌。

## 安裝

需要 macOS；選單列另需安裝 [SwiftBar](https://swiftbar.app/)。在 repo 目錄執行：

```bash
./install.command             # 只安裝 CLI 與選單，不改路由
./install.command --routing   # 同時啟用分流服務，需要 sudo
```

CLI 位於 `~/.local/bin/vpn-split`，請將 `~/.local/bin` 加入 `PATH`。SwiftBar 沿用既有插件目錄，未設定時請選擇 `~/.config/swiftbar`。重複安裝即為更新，保留 `~/.config/vpn-split/` 的設定。

啟用分流前先連上 VPN，再用 `vpn-split routing-plan` 檢查支援狀態。遠端操作請保留獨立復原連線；安裝完成後用 `vpn-split doctor` 確認實際套用結果。

## 設定 VPN 控制

預設在 VPN 客戶端手動連線。若要從工具控制連線，選擇其中一種方式：

```bash
vpn-split config manual                                     # 手動，預設
vpn-split config scutil 'My VPN'                            # macOS VPN 服務
vpn-split config hooks /path/to/connect /path/to/disconnect  # 自訂可執行腳本
```

macOS 服務名稱可用 `scutil --nc list` 查詢。Hook 不接收參數，只以一般使用者執行；工具不保存 VPN 密碼。設定後可用 `vpn-split connect` 與 `vpn-split disconnect`，但控制命令成功不等於分流已套用。

## 使用

```bash
vpn-split add example.org 192.0.2.10 198.51.100.0/24
vpn-split remove example.org
vpn-split list
vpn-split mode split       # 清單目標走 VPN
vpn-split mode full        # 恢復 VPN 原本的全隧道路由
vpn-split status           # 出口 IP、延遲與各網站路徑
vpn-split check example.org
vpn-split health
vpn-split speedtest        # 下載 10 MB，測量目前路徑
```

也可從選單列操作，或直接編輯 `~/.config/vpn-split/hosts.txt`，一行一項，可加註解。清單不支援萬用字元，網域不會自動包含子網域。

狀態會區分「出口 IP」與「網站伺服器 IP」。要在分流模式顯示 VPN 出口，可執行 `vpn-split add api.ipify.org`；只有確認該測試連線走 VPN 才採用結果。診斷會連線至 Cloudflare、選用的 ipify 與受測網站，不會上傳整份清單。

## 限制

- 支援 IPv4 point-to-point `utun`，且 VPN 建立同一介面的兩條互補 `/1` 路由，並保有非 VPN 的 default 路由。不代表所有 VPN 客戶端都相容。
- 分流依 DNS 解析後的 IP 設定路由，共用 IP 的網站可能一起走 VPN，DNS 更新也可能影響既有連線。
- 不管理 IPv6 或 DNS 設定，不是防洩漏工具。VPN 專用 DNS 若需經隧道存取，請將其 IPv4 加入清單。
- 多 VPN 或其他路由工具可能造成衝突。修改前會記錄復原資訊；遇到衝突請先斷開 VPN，再移除分流服務，不要直接刪除 state。

## 移除與開發

```bash
./uninstall.command           # 移除 CLI 與選單，保留設定
./uninstall.command --routing # 先停用並復原路由，再移除工具
make check                    # 開發驗證，需要 Python 3 與 ShellCheck
```

執行工具本身只需系統 Bash 3.2。測試以 mock 驗證路由、provider 與安裝流程，不改動開發機網路；GitHub CI 執行相同檢查。
