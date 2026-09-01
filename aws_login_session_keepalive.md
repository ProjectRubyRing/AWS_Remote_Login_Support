# aws login --remote で離席してもトークンを適用できるようにする

`aws_login_check.sh` を TeraTerm から実行し、表示された OAuth URL を
「AWS コンソールに繋がる別座席」まで運んでいる間に離席すると、
戻ってきたときには SSH セッションが切れていてトークンを貼り付けられない
—— この問題の原因と対策をまとめる。

対策の実装として `aws_login_persist.sh` を追加した。

---

## 0. 結論（先に読む場合はここだけ）

| やりたいこと | 答え |
|---|---|
| 離席中も待機画面を維持したい | SSH を維持するのではなく、**ログイン処理を tmux に入れて SSH から切り離す**。`./aws_login_persist.sh start` |
| セッションが切れた後にトークンを適用したい | **`aws login` プロセスが生きていれば可能**（`./aws_login_persist.sh token <TOKEN>`）。プロセスが死んでいたら**不可能**。URL を取り直すしかない |
| TeraTerm 側でも粘りたい | SSH ハートビート・sshd の ClientAlive・TMOUT・経路のアイドル切断を潰す（§3）。ただし「切れない保証」にはならない |
| 往復そのものをやめたい | 座席B から Session Manager で同じインスタンスに入り、そこからトークンを注入する（§5） |

つまり **「切れないようにする」ではなく「切れても困らないようにする」** が正解。

---

## 1. 何が「切れて」いるのか —— 3 つのレイヤ

この問題は 3 つの独立した層が絡んでいる。どれが原因かで打つ手が変わる。

```
  ┌─ (A) TCP / SSH セッション ──────────────────────────┐
  │    TeraTerm ── ネットワーク ── sshd                  │
  │      切れる要因: NAT/FW のアイドル切断、             │
  │                  ハートビート無効、回線断             │
  │                                                      │
  │  ┌─ (B) aws login プロセス ────────────────────┐    │
  │  │    (A) が切れると sshd が SIGHUP を送り、    │    │
  │  │    フォアグラウンドのプロセスは道連れで死ぬ  │    │
  │  │                                              │    │
  │  │  ┌─ (C) 認可コードの有効期限 ───────────┐   │    │
  │  │  │   (A)(B) が無事でも、時間が経つと     │   │    │
  │  │  │   トークン自体が失効して弾かれる      │   │    │
  │  │  └───────────────────────────────────────┘   │    │
  │  └──────────────────────────────────────────────┘    │
  └──────────────────────────────────────────────────────┘
```

重要なのは次の 2 点。

- **(B) さえ生きていれば (A) は切れてよい。** tmux などで (B) を (A) から切り離せば、
  TeraTerm を閉じてしまっても待機状態は維持される。
- **(A) をどれだけ頑張って維持しても (C) は守れない。** 認可コードの有効期限は
  サーバ側の都合なので、往復に時間がかかりすぎればどのみち失効する。

---

## 2. なぜ「セッションが切れた後にトークンだけ適用」ができないのか

結論から言うと、**`aws login --remote` のプロセスが死んだ時点で、
そのとき取得したトークンは使えなくなる**。理由は 2 つ。

1. **交換に必要な状態がプロセス内メモリにしかない。**
   この種の OAuth フローでは、URL を発行する際に CLI 側が
   `code_verifier`（PKCE）や `state`、一時的なクライアント登録情報を作る。
   ブラウザで受け取ったトークン（認可コード）は、**それらとセットでないと**
   アクセストークンに交換できない。プロセスが死ねば道連れで失われる。

2. **中断したフローを再開するコマンドが存在しない。**
   `aws login` に「途中から再開する」ようなサブコマンド／オプションは無い。
   `aws login --remote` をもう一度実行すれば、それは**新しいフロー**であり、
   前の URL に対して取得したトークンは対応しない。

したがって取れる手は次の 2 つしかない。

- **(B) を殺さない** → §4（tmux / FIFO でプロセスを切り離す）
- **往復時間そのものを短くする** → §5（戻らずに注入する）

> `aws_login_persist.sh token` は、プロセスが既に死んでいる場合に
> この理由を表示して中断する。無駄に貼り付けを試して悩まなくて済むようにしてある。

---

## 3. 対策A: セッションを切れにくくする（対症療法）

本命は §4 だが、こちらも併用したほうが快適なので一通り潰しておく。
現在値の確認は `./aws_login_persist.sh doctor` でまとめて行える。

### 3.1 TeraTerm 側（接続元 Windows）

| 項目 | 設定場所 | 推奨値 |
|---|---|---|
| SSH ハートビート | `[設定] → [SSH...]` の *Heartbeat(KeepAlive) interval* | `60`（秒）。`0` は無効なので要確認 |
| 同上（ini 直接） | `TERATERM.INI` の `[TTSSH]` セクション | `HeartBeat=60` |
| 自動ウィンドウクローズ | `[設定] → [TCP/IP...]` の *Auto window close* | オフ（切断理由を画面に残すため） |
| リモートからのクリップボード | `[設定] → [その他の設定] → [制御シーケンス]` | 「書き込み」以上（`ClipboardAccessFromRemote=write`） |
| OSC バッファ | `TERATERM.INI` | `MaxOSCBufferSize=1000000`（既定 4096 だと長い URL が切れる） |

設定後は必ず `[設定] → [設定の保存(Save setup...)]` を実行してから接続し直すこと。

ハートビートは無通信時でも定期的にパケットを送るので、
NAT や FW のアイドル切断（§3.5）に対して最も効く。

### 3.2 OpenSSH クライアントを使う場合（`ssh` コマンド、`~/.ssh/config`）

```
Host ec2-*
    ServerAliveInterval 60      # 60 秒ごとにサーバへ生存確認を送る
    ServerAliveCountMax 60      # 60 回連続で無応答なら切断（= 60 分猶予）
    TCPKeepAlive yes
```

`ServerAliveInterval` の既定は `0`（＝送らない）。ここが効いていないケースは多い。

### 3.3 EC2 側 sshd（`/etc/ssh/sshd_config`）

```
ClientAliveInterval 60
ClientAliveCountMax 60
```

- `ClientAliveInterval` の既定は `0` で、この場合 **sshd 側からは切らない**。
  逆に、CIS ベンチマーク等で `ClientAliveInterval 300` / `ClientAliveCountMax 0`
  のようなハードニングが入っていると、**5 分の無操作で切られる**。
  まずここを疑う価値がある。
- 変更したら `sudo systemctl reload sshd`。既存セッションには影響しない。

### 3.4 シェルのアイドルタイムアウト（`TMOUT`）

```bash
grep -rn TMOUT /etc/profile /etc/profile.d /etc/bashrc 2>/dev/null
echo "${TMOUT:-未設定}"
```

- `TMOUT` は **シェルがプロンプトで入力待ちのときだけ**働く。
  `aws login` が前面で動いている間は発火しない。
- ただしログイン直後やログイン処理の前後でシェルが `TMOUT` で落ちると、
  tmux の外で動かしているログイン処理も道連れになる。
- ハードニングで `readonly TMOUT` にされていると `unset TMOUT` できない。
  この場合も **tmux に逃がすのが現実的な回避策**（tmux のセッションは
  ログインシェルが落ちても残る）。

### 3.5 経路上のアイドル切断（代表的な既定値）

| 経路上の要素 | アイドルタイムアウト | 変更可否 |
|---|---|---|
| NAT ゲートウェイ | 350 秒 | 変更不可 |
| Network Load Balancer | 350 秒 | 不可（TCP リスナー） |
| Session Manager のアイドル | 既定 20 分 | Session Manager の設定で 1〜60 分に変更可 |
| 社内 FW / VPN | 製品依存（数分〜） | ネットワーク管理者に確認 |

いずれも「**無通信**で切る」ので、ハートビートで通信を流し続ければ回避できる。
`350 秒` に対して `60 秒` 間隔のハートビートなら十分な余裕がある。

### 3.6 スクリプト側のキープアライブ

TeraTerm 側の設定を変えられない場合の保険として、
サーバ側から無害な制御シーケンスを定期送信する機能を用意した。

```bash
./aws_login_persist.sh keepalive        # 既定 50 秒間隔
./aws_login_persist.sh keepalive 30     # 間隔を指定
```

送っているのは DECSC（`ESC 7` = カーソル位置と属性の保存）と
DECRC（`ESC 8` = その復元）の対で、**画面表示には一切影響しない**。
`start` / `attach` の実行中は自動的にバックグラウンドで動く
（不要なら `KEEPALIVE=0`）。

### 3.7 対策A の限界

ここまで全部やっても「切れない保証」は得られない。
無線 LAN の切り替わり、VPN の再接続、PC のスリープ、
ネットワーク機器の再起動などは防ぎようがない。
**だから §4 が必要になる。**

---

## 4. 対策B: ログイン処理を SSH から切り離す（本命）

### 4.1 なぜ tmux で解決するのか

通常、SSH セッションが切れると sshd はその端末のフォアグラウンドプロセスグループへ
`SIGHUP` を送る。`aws login --remote` はこれで死ぬ。

tmux はサーバプロセスとして独立して動き、その中のプロセスは
**擬似端末（pty）ごと tmux が保持する**。SSH が切れて tmux クライアントが
居なくなっても、pty も `aws login` もそのまま残る。
再接続して `tmux attach` すれば、**トークン入力待ちのプロンプトがそのまま出てくる**。

```
  切断前:  TeraTerm ── sshd ── tmux server ── pty ── aws login (入力待ち)
                                     ↑ ここから左が消えても
  切断後:                         tmux server ── pty ── aws login (入力待ちのまま)
  再接続:  TeraTerm ── sshd ── tmux server ── pty ── aws login (そのまま貼り付け可)
```

RHEL9 なら AppStream に入っている。

```bash
sudo dnf install -y tmux
```

### 4.2 tmux が使えない場合（FIFO + script 方式）

tmux を入れられない環境向けのフォールバックも実装した。原理は次の通り。

1. 名前付きパイプ（FIFO）を作り、`aws login` の標準入力にする
2. `sleep` プロセスに FIFO の**書き込み側を開いたまま保持させる**
   —— これが無いと、トークンを 1 回書いた時点で `aws login` が EOF を検知して終了してしまう
3. `setsid` で端末から切り離し、`script(1)` 経由で擬似端末を与える
   （`aws login` が端末を要求する実装でも動くようにするため）
4. あとから別セッションで FIFO に書き込めば、待機中の `aws login` に届く

```
                         ┌─ sleep (書き込み側を保持し EOF を防ぐ)
                         │
   token サブコマンド ──→ FIFO ──→ script(pty) ──→ aws login (入力待ち)
                                                        │
                                             login.log ←┘
```

`script(1)` が無い環境ではさらに pty 無しでの起動にフォールバックする
（`aws login` が端末を要求しない実装なら動く）。

自動判定なので通常は意識しなくてよい。強制したい場合は `PERSIST_MODE=tmux|fifo`。

### 4.3 `aws_login_persist.sh`

`aws_login_check.sh` を置き換えるものではなく、**その外側に被せるラッパー**。
tmux（または FIFO）の中で `aws_login_check.sh` を実行するので、
OSC52 コピー・TeraTerm 設定ガイド・Session Manager 対応といった
既存の機能はそのまま効く。

| サブコマンド | 説明 |
|---|---|
| `start` | 永続セッションを作りログイン開始。URL を自動コピーして表示 |
| `url` | 取得済み URL を再表示・再コピー（コピーし損ねたとき） |
| `attach` | 待機中のセッションへ戻る |
| `token [TOKEN]` | attach せずにトークンを注入。省略時は標準入力から読む |
| `status` | 状態・経過時間・直近の出力を表示 |
| `restart` | セッションを作り直して URL を取り直す |
| `stop` / `purge` | 停止 / 作業ディレクトリごと削除 |
| `keepalive [秒]` | 無害な通信を流し続ける（§3.6） |
| `doctor` | 切断要因になりうる設定をまとめて診断 |

tmux 使用時は次の設定を自動で入れている。

- `set-clipboard on` —— 中のアプリが送る OSC52 を外側の端末へ転送する
  （既定の `external` では転送されない）
- `allow-passthrough on` —— `aws_login_check.sh` は tmux 内では DCS パススルー形式で
  OSC52 を送るため。tmux 3.3 以降はこれが既定で無効
- `history-limit 20000` —— 後から `capture-pane` で URL を拾えるように
- `remain-on-exit on` —— ログイン完了後も結果画面を残す

---

## 5. 対策C: 往復そのものをやめる

`(A)` と `(B)` を解決しても `(C)`（認可コードの失効, §6）は残る。
往復に 10 分以上かかるなら、往復自体を削るのが本質的な対策になる。

### 5.1 座席B から Session Manager でトークンを注入する【推奨】

座席B は「AWS コンソールに繋がる環境」なのだから、
**同じコンソールから Session Manager で同じ EC2 インスタンスに入れる**ことが多い。
入れるなら座席A に戻る必要はない。

```
座席A (TeraTerm)          座席B (ブラウザ / AWS コンソール)
  start                →   ① URL をブラウザで開いて認証、トークン取得
  detach して離席           ② 同じコンソールから Session Manager で EC2 に接続
                            ③ ./aws_login_persist.sh token <TOKEN>
                            ④ ./aws_login_persist.sh status で成功を確認
```

往復（A→B→A）が片道（A→B）になるので、失効リスクが大きく下がる。

> Session Manager のブラウザ端末は OSC52 に対応していないため自動コピーはできないが、
> `aws_login_check.sh` がダブルクリックで選択できる COPY ブロックを出してくれる。
> トークンの貼り付け（ブラウザ → 端末）は Ctrl+V で普通にできる。

### 5.2 そもそも座席B で完結させる

座席B から Session Manager に入れるなら、ログイン自体を座席B で始めればよい。

```bash
# 座席B の Session Manager 端末で
./aws_login_check.sh          # ブラウザ端末を自動検出して COPY ブロックを表示
# → 別タブで URL を開いて認証 → トークンを同じ端末に Ctrl+V
```

移動が発生しないので最も確実。座席A の TeraTerm を使う必然性が無いなら、これが最短。

### 5.3 URL とトークンの受け渡しを物理移動からネットワーク経由にする

ファイルを持ち歩いているのが遅さの原因なら、経路を変える。

```bash
# 座席A: URL を S3 経由で渡す
aws s3 cp ~/.aws_login_persist/aws-login/url.txt s3://<bucket>/<key>

# 座席B: コンソールの S3 画面からダウンロード、または署名付き URL を発行
aws s3 presign s3://<bucket>/<key>
```

社内の共有ストレージやチャットが使えるならそれでもよい。
`aws_login_persist.sh url` は常に `~/.aws_login_persist/<セッション名>/url.txt` に
URL を保存しているので、そのファイルを渡せばよい。

### 5.4 IAM Identity Center 構成なら device flow も検討する

認証基盤が IAM Identity Center（SSO）ベースなら、
`aws sso login --no-browser` はデバイス認可フローで動く。
このフローは **トークンを端末に貼り戻す必要がない**（CLI 側がポーリングして
ブラウザでの承認を待つ）ため、座席B で承認するだけで座席A の CLI が自動的に完了する。

```bash
grep -n "sso" ~/.aws/config      # sso-session / sso_start_url があるか確認
```

該当するなら、tmux と組み合わせることで「戻ってきたら既にログイン済み」にできる。
`aws login --remote` を使う必要がある構成かどうかは、事前に確認しておくとよい。

---

## 6. 認可コードの有効期限（レイヤ C）

- OAuth 2.0 の仕様（RFC 6749 §4.1.2）は認可コードの寿命について
  **「最大 10 分を推奨」** としている。AWS 側の実装値は公開されていない。
- したがって「**URL を発行してから 10 分以内にトークンを投入する**」を
  目標にしておくのが安全側。
- `aws_login_persist.sh` は URL 発行時刻を記録し、
  `status` / `token` / `url` の実行時に経過時間を表示する。
  既定で 8 分超過で警告、10 分超過で失効の可能性を明示する
  （`CODE_TTL_WARN` / `CODE_TTL_LIMIT` で調整可能）。

### 自分の環境での実測方法

公開値が無いので、一度だけ測っておくと運用判断がしやすい。

```bash
./aws_login_persist.sh start        # URL 取得、detach
# → ブラウザでトークンを取得したら、あえて N 分待ってから投入する
./aws_login_persist.sh token <TOKEN>
./aws_login_persist.sh status       # 成功したか、失効エラーが出たかを記録
```

N を 5 分・10 分・15 分と変えて数回試せば、実用上の上限が分かる。

---

## 7. 運用チェックリスト

### 事前（初回だけ）

- [ ] `sudo dnf install -y tmux`（無ければ FIFO モードで動くが tmux 推奨）
- [ ] `./aws_login_persist.sh doctor` で sshd / TMOUT / 経路の設定を確認
- [ ] TeraTerm: ハートビート 60 秒、リモートクリップボード「書き込み」、
      `MaxOSCBufferSize` 拡大（§3.1）→ 設定を保存
- [ ] 座席B から Session Manager でこのインスタンスに入れるか確認（§5.1）
- [ ] URL の受け渡し経路（S3 / 共有ストレージ）を用意できるか確認（§5.3）

### 毎回

1. 座席A で `./aws_login_persist.sh start`
2. 表示された URL がクリップボードに入ったか確認
   （入っていなければ COPY ブロックから手動コピー、または `url` で再コピー）
3. `Ctrl-b` → `d` で detach。**TeraTerm は閉じてよい**
4. 座席B でブラウザを開いて認証し、トークンを取得
5. トークンを投入する（どちらか）
   - 座席B の Session Manager から `./aws_login_persist.sh token <TOKEN>`
   - 座席A に戻って `./aws_login_persist.sh attach` して貼り付け、
     または `./aws_login_persist.sh token <TOKEN>`
6. `./aws_login_persist.sh status` で成功を確認
7. `./aws_login_persist.sh stop` で片付け

---

## 8. トラブルシューティング

| 症状 | 原因 / 対処 |
|---|---|
| `token` が「待機中のセッションがありません」と言う | `aws login` プロセスが死んでいる。そのトークンは使えない（§2）。`restart` で取り直す |
| `token` は通ったが認証に失敗する | 認可コードの失効（§6）か、トークンの貼り付けミス。`status` の経過時間を確認して `restart` |
| `attach` しても画面が真っ暗 | ログイン処理が既に終了して `remain-on-exit` のペインが残っている。`status` で終了コードを確認し、`restart` |
| URL がクリップボードに入らない | TeraTerm のリモートクリップボードが無効（§3.1）。または `MaxOSCBufferSize` 不足。`url` で再コピー、それでもだめなら COPY ブロックから手動コピー |
| tmux 内で OSC52 が効かない | tmux 3.3 以降の `allow-passthrough` / `set-clipboard`。`start` / `attach` 経由なら自動設定されるので、素の `tmux attach` ではなくこちらを使う |
| `start` が「FIFO モードで起動します」と言う | tmux が入っていない。動作はするが `sudo dnf install -y tmux` を推奨 |
| 「script(1) が無いため擬似端末なしで起動」と出る | `util-linux` が最小構成。`aws login` が端末を要求する場合は失敗するので tmux を導入する |
| detach したのに数分で死んでいる | tmux ではなく素のバックグラウンド実行になっていないか確認。`status` の「永続化方式」を見る |
| 毎回すぐ切れる | まず `doctor` で sshd の `ClientAliveInterval` を確認。ハードニングで短く設定されていることが多い（§3.3） |

---

## 9. コマンドリファレンス

```bash
# 基本
./aws_login_persist.sh start                 # 開始（URL 自動コピー、そのまま画面に入る）
./aws_login_persist.sh url                   # URL を再表示・再コピー
./aws_login_persist.sh attach                # 待機画面へ戻る
./aws_login_persist.sh token ABC123XYZ       # 画面に戻らずトークン投入
cat token.txt | ./aws_login_persist.sh token # ファイルから投入
./aws_login_persist.sh status                # 状態確認
./aws_login_persist.sh restart               # URL を取り直す
./aws_login_persist.sh stop                  # 停止（ログは残す）
./aws_login_persist.sh purge                 # 作業ディレクトリごと削除

# 診断・補助
./aws_login_persist.sh doctor                # 切断要因の診断
./aws_login_persist.sh keepalive 30          # 30 秒間隔でキープアライブ

# 環境変数
PERSIST_MODE=fifo    ./aws_login_persist.sh start   # 方式を強制
PERSIST_SESSION=dev  ./aws_login_persist.sh start   # 複数プロファイルを並行運用
AWS_PROFILE=prod     ./aws_login_persist.sh start   # プロファイル指定（tmux に引き継がれる）
KEEPALIVE=0          ./aws_login_persist.sh start   # 自動キープアライブ無効
CODE_TTL_LIMIT=900   ./aws_login_persist.sh status  # 実測値に合わせて警告しきい値を調整
USE_CHECK_SCRIPT=0   ./aws_login_persist.sh start   # aws_login_check.sh を使わず LOGIN_CMD を直接実行
```

### 作業ディレクトリの構成

```
~/.aws_login_persist/<セッション名>/
├── clip/           aws_login_check.sh が保存した URL（CLIP_SAVE_DIR）
├── url.txt         検出した OAuth URL
├── url_at          URL 発行時刻（epoch）— 経過時間の計算に使う
├── started_at      開始時刻（epoch）
├── exit_code       ログイン処理の終了コード（実行中は存在しない）
├── mode            tmux / fifo
├── login.log       FIFO モードの出力ログ
├── stdin.fifo      FIFO モードの入力パイプ
└── runner.sh       自動生成されるランチャー
```

---

## 10. 補足: 一度ログインできた後

`aws login` に成功すると、取得したトークンは `~/.aws/` 配下にキャッシュされる。
以降は有効期限が切れるまで再ログイン不要なので、この往復作業は毎回発生するわけではない。

```bash
aws sts get-caller-identity     # 認証済みかどうかの確認（aws_login_check.sh と同じ判定）
```

`aws_login_check.sh` は最初にこの確認をして、認証済みなら何もせず終了する。
`aws_login_persist.sh start` 経由でも同じなので、まず走らせてみて
「認証済みです」と出れば作業自体が不要ということになる。
