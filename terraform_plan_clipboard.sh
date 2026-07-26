#!/usr/bin/env bash
#
# terraform_plan_clipboard.sh
#   Terraform の plan 実行フォルダで `terraform plan` を実行し、
#   結果を「みやすい形式」に整形してクリップボードへコピーするスクリプト。
#
#   AWS の認証チェックと Terraform の実行権限チェックは、このスクリプト内で
#   再実装せず、他プロジェクトの common.sh に用意された関数へ
#   「スイッチバック (委譲)」して行う。common.sh に該当関数が無い場合は、
#   このスクリプト内の簡易フォールバック実装で代替する。
#
# 使い方:
#   ./terraform_plan_clipboard.sh [plan実行フォルダ]
#
#   例:
#     ./terraform_plan_clipboard.sh                 # カレントディレクトリで実行
#     ./terraform_plan_clipboard.sh ./envs/prod     # 指定フォルダで実行
#
# 環境変数 (省略可):
#   COMMON_SH_PATH
#       他プロジェクトの common.sh のパスを明示指定する。
#       未指定の場合は下記の候補パスを順に探索する。
#   COMMON_AWS_AUTH_FUNC
#       common.sh 内の「AWS 認証チェック関数」名。未指定なら候補名を自動探索。
#   COMMON_TF_PERM_FUNC
#       common.sh 内の「Terraform 実行権限チェック関数」名。未指定なら自動探索。
#   TF_PLAN_ARGS
#       terraform plan に追加で渡す引数 (例: "-var-file=prod.tfvars")。
#
# クリップボードについて (aws_login_check.sh と同じ仕組みを利用):
#   ヘッドレスな EC2 には OS クリップボードがないため、優先順位は以下の通り。
#     1. xclip / xsel (X11 転送がある場合)
#     2. wl-copy (Wayland の場合)
#     3. OSC52 エスケープシーケンス
#        → SSH 接続元のローカル端末 (Windows Terminal / iTerm2 など) の
#          クリップボードに直接コピーされる。ヘッドレス環境ではこれが本命。
#        ※ tmux 内で使う場合は `set -g set-clipboard on` が必要。
#
#   ★ TeraTerm のリモートクリップボード (OSC52) で「貼り付けが途中で切れる」場合:
#       TeraTerm はリモートから受信する OSC 制御文字列を teraterm.ini の
#       MaxOSCBufferSize (既定 4096 バイト) までしかバッファリングせず、
#       それを超えた分は破棄する。terraform plan 出力のような長い文字列は
#       base64 化すると容易に 4096 バイトを超えるため、貼り付けが途中で
#       切れてしまう。
#       → 対策: TeraTerm の teraterm.ini で MaxOSCBufferSize を十分大きな値
#         (例: MaxOSCBufferSize=1000000) に設定して TeraTerm を再起動する。
#         設定箇所は [設定]-[その他の設定]-... または teraterm.ini の直接編集。
#       本スクリプトは送信する OSC52 データ長を計算し、上限を超えそうな場合に
#       警告と推奨バッファサイズを表示する。想定するバッファ上限は環境変数
#       OSC52_BUFFER_LIMIT で上書きできる (既定 4096 = TeraTerm の既定値)。
#
#   ★ TeraTerm でコピーしても「貼り付けできない」/「クリップボードアクセスの
#       拒否」ダイアログが出る場合:
#       TeraTerm はセキュリティ上、リモート (SSH 先) からのクリップボード書き込みを
#       既定で無効 (ClipboardAccessFromRemote=off) にしている。この状態だと OSC52 の
#       コピーは黙って破棄されるため、貼り付けても何も入らない。
#       → 対策: TeraTerm の「リモートからのクリップボードアクセス」を「書き込み」
#         以上に変更する。本スクリプトは OSC52 でコピーする際、有効化手順を
#         分かりやすく案内する。設定済みなら環境変数 OSC52_GUIDE=0 で抑制できる。
#
#   ★ AWS マネジメントコンソールの Session Manager (Chrome / Edge のブラウザ端末)
#       から接続している場合:
#       ブラウザ端末は xterm.js ベースで、OSC52 (リモートからのクリップボード
#       書き込み) を実装していない。送信しても黙って破棄されるため、
#       「コピーしたはずなのに別ブラウザに貼り付けられない」状態になる。
#       → 対策: 本スクリプトは Session Manager セッションを自動検出し、
#         (1) OSC52 も従来どおり送信しつつ (ローカル端末から
#             `aws ssm start-session` で入っている場合はこれで成功する)
#         (2) ブラウザ上でドラッグ選択しやすいコピー最適化ブロックとして
#             整形済み plan 結果を表示し
#         (3) 同じ内容をファイルへ保存して後から取り出せるようにする。
#       ※ terraform plan の出力は長くなりやすく、画面スクロールでの選択が
#         困難なため、ブラウザ端末では (3) の保存ファイルからの取り出しが
#         最も確実。案内文にも取り出し手順を表示する。
#
# クリップボード関連の環境変数 (省略可):
#   OSC52_BUFFER_LIMIT  想定する OSC バッファ上限バイト数 (既定 4096)
#   OSC52_GUIDE         0 で TeraTerm 設定ガイドを抑制
#   CLIP_MODE           auto (既定) / osc52 / browser
#                       auto は端末種別を自動判定する。判定を上書きしたい場合に指定。
#                         osc52   … 従来どおり OSC52 のみ (TeraTerm / SSH 端末)
#                         browser … Session Manager (ブラウザ) 向け表示を強制
#   SSM_GUIDE           0 で Session Manager 用のコピー手順案内を抑制
#   SSM_OSC52           0 で Session Manager 判定時の OSC52 併送を停止 (既定 1)
#   CLIP_SAVE           0 でコピー内容のファイル保存を無効化 (既定 1)
#   CLIP_SAVE_DIR       コピー内容の保存先ディレクトリ (既定 ~/.aws_clip)
#
set -u

# TeraTerm 等の OSC バッファ上限 (バイト)。これを超える OSC52 データは
# 受信側で切り詰められる可能性があるため、事前に警告する。
# TeraTerm 側で MaxOSCBufferSize を引き上げている場合は、この変数にも
# 同じ値を設定しておくと不要な警告を抑制できる。
OSC52_BUFFER_LIMIT="${OSC52_BUFFER_LIMIT:-4096}"

# OSC52 (TeraTerm 等) でコピーする際に、リモートクリップボードの有効化手順を
# 案内するかどうか。設定済みで案内が不要な場合は OSC52_GUIDE=0 を指定する。
OSC52_GUIDE="${OSC52_GUIDE:-1}"

# --- ここから Session Manager (ブラウザ) 対応で追加した設定 -------------------

# クリップボード方式。auto なら detect_terminal() で自動判定する。
#   osc52   … 従来どおり OSC52 のみ (TeraTerm / SSH 端末)
#   browser … Session Manager (ブラウザ) 向けのコピー最適化表示を強制
CLIP_MODE="${CLIP_MODE:-auto}"

# Session Manager (ブラウザ) で使う際のコピー手順案内を出すかどうか。
SSM_GUIDE="${SSM_GUIDE:-1}"

# Session Manager 判定時に OSC52 も併せて送るかどうか (1=送る)。
# ローカル端末から `aws ssm start-session` で入っている場合は、これで
# 従来どおりクリップボードへコピーできる。画面が乱れる端末では 0 にする。
SSM_OSC52="${SSM_OSC52:-1}"

# コピー対象をファイルにも保存するかどうか (1=保存する)。
# ブラウザ端末では自動コピーができないため、取り逃した場合の保険として残す。
# terraform plan の出力は長く、画面からの選択が難しいので特に有用。
CLIP_SAVE="${CLIP_SAVE:-1}"
CLIP_SAVE_DIR="${CLIP_SAVE_DIR:-${HOME:-/tmp}/.aws_clip}"

# copy_to_clipboard() が実際に使用した方式を呼び出し元へ伝えるための変数。
#   osc52 / browser のいずれかが入る。
CLIP_LAST_MODE=""

# ---------------------------------------------------------------
# TeraTerm 「リモートからのクリップボードアクセス」有効化ガイド。
#   TeraTerm は既定でリモート (SSH 先) からのクリップボード書き込みを
#   無効 (ClipboardAccessFromRemote=off) にしているため、OSC52 でコピー
#   しても黙って破棄され、貼り付けできない/「クリップボードアクセスの
#   拒否」ダイアログが出る。その場合の設定箇所と手順を案内する。
#   OSC52_GUIDE=0 でこの案内を抑制できる。
# ---------------------------------------------------------------
print_teraterm_clipboard_guide() {
    [ "$OSC52_GUIDE" = "0" ] && return 0
    cat >&2 <<'EOF'

--------------------------------------------------------------------
[TeraTerm クリップボード設定ガイド]
  貼り付けできない/「クリップボードアクセスの拒否」と表示される場合は、
  TeraTerm の「リモートからのクリップボードアクセス」が無効 (既定値) です。
  下記のいずれかの方法で「書き込み」を許可してください。

  ■ メニューから設定する場合 (推奨)
    1. [設定(Setup)] → [その他の設定(Additional settings...)] を開く
    2. [制御シーケンス(Control Sequence)] タブを選ぶ
    3. [リモートからのクリップボードアクセス(Clipboard access from remote)]
       を「書き込み(write)」または「読み書き(on)」に変更する
    4. (任意) [リモートからのクリップボードアクセスを通知する] のチェックを
       外すと、コピーのたびに確認ダイアログが出なくなります
    5. [OK] を押し、[設定(Setup)] → [設定の保存(Save setup...)] で保存後、
       接続し直してから再実行してください

  ■ teraterm.ini を直接編集する場合
      ClipboardAccessFromRemote=write   ; off(既定)/write/read/on から選択
      NotifyClipboardAccess=off         ; 確認ダイアログを出したくない場合
    保存後に TeraTerm を再起動してください。

  ■ 起動オプションで指定する場合
      ttermpro.exe /OSC52=write

  すでに設定済みの場合は OSC52_GUIDE=0 を付けて実行すると、この案内を
  非表示にできます。
--------------------------------------------------------------------
EOF
}

# ===============================================================
# ここから Session Manager (ブラウザ) 対応で追加した処理。
#   従来の OSC52 経路 (osc52_copy) には手を加えていない。
#   ※ aws_login_check.sh と同一の仕組み。
# ===============================================================

# ---------------------------------------------------------------
# 自プロセスの祖先に SSM のセッションワーカーがいるかどうかを調べる。
#   Session Manager 接続時のプロセス系譜は
#     amazon-ssm-agent → ssm-agent-worker → ssm-session-worker → shell
#   となるため、これを遡って判定する。
#   ※ /proc/<pid>/comm は 15 文字で切り詰められるので、フルパスが入る
#     /proc/<pid>/cmdline を優先して見る。
# ---------------------------------------------------------------
has_ssm_ancestor() {
    local pid="$$"
    local ppid cmd depth=0

    while [ "$depth" -lt 20 ]; do
        case "$pid" in
            ''|*[!0-9]*) return 1 ;;
        esac
        [ "$pid" -le 1 ] && return 1
        [ -d "/proc/${pid}" ] || return 1

        cmd="$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null)"
        [ -n "$cmd" ] || cmd="$(cat "/proc/${pid}/comm" 2>/dev/null)"
        case "$cmd" in
            *ssm-session-wor*|*ssm-agent-work*|*ssm-document-wo*|*amazon-ssm-agen*)
                return 0
                ;;
        esac

        ppid="$(awk '/^PPid:/{print $2; exit}' "/proc/${pid}/status" 2>/dev/null)"
        [ -n "$ppid" ] || return 1
        pid="$ppid"
        depth=$((depth + 1))
    done
    return 1
}

# ---------------------------------------------------------------
# 端末種別の判定。標準出力へ osc52 / browser のいずれかを返す。
#   CLIP_MODE で明示指定されていればそれを優先する。
#
#   注意: インスタンス側からは「ブラウザのコンソール端末」と
#   「ローカル端末の session-manager-plugin」を区別できない
#   (どちらも同じ ssm-session-worker 配下)。そのため browser と
#   判定した場合も OSC52 の送信自体は併せて行い、両対応にしている。
# ---------------------------------------------------------------
detect_terminal() {
    case "$CLIP_MODE" in
        osc52|browser)
            printf '%s' "$CLIP_MODE"
            return 0
            ;;
    esac

    # SSM のセッションワーカー配下で動いている
    if has_ssm_ancestor; then
        printf 'browser'
        return 0
    fi

    # SSH 由来の環境変数が一切なく、実行ユーザが SSM 既定の ssm-user
    if [ -z "${SSH_CONNECTION:-}${SSH_CLIENT:-}${SSH_TTY:-}" ] \
        && [ "$(id -un 2>/dev/null)" = "ssm-user" ]; then
        printf 'browser'
        return 0
    fi

    printf 'osc52'
}

# ---------------------------------------------------------------
# コピー対象をファイルへ保存する。
#   保存できたらパスを標準出力へ返す。保存しない/失敗した場合は空。
#   ブラウザ端末では自動コピーができないため、選択に失敗しても
#   後から取り出せるようにしておく。
# ---------------------------------------------------------------
save_clip_file() {
    local text="$1"
    local file

    [ "$CLIP_SAVE" = "0" ] && return 1
    mkdir -p "$CLIP_SAVE_DIR" 2>/dev/null || return 1

    file="${CLIP_SAVE_DIR}/$(date '+%Y%m%d-%H%M%S')-$$.txt"
    ( umask 077; printf '%s\n' "$text" > "$file" ) 2>/dev/null || return 1

    printf '%s' "$file"
}

# ---------------------------------------------------------------
# OSC52 を「警告・案内なし」で送るだけの版。
#   Session Manager 経路では TeraTerm 向けの案内が的外れになるため、
#   従来の osc52_copy() には手を加えず、送信部分だけを別に用意する。
#   ブラウザ端末 (xterm.js) は OSC を解釈したうえで破棄するので、
#   画面が壊れることはない。
# ---------------------------------------------------------------
osc52_emit_quiet() {
    local text="$1"
    local b64

    b64=$(printf '%s' "$text" | base64 | tr -d '\n')

    if [ -n "${TMUX:-}" ]; then
        printf '\033Ptmux;\033\033]52;c;%s\a\033\\' "$b64" > /dev/tty 2>/dev/null
    else
        printf '\033]52;c;%s\a' "$b64" > /dev/tty 2>/dev/null
    fi
    return 0
}

# ---------------------------------------------------------------
# Session Manager (ブラウザ) 用のコピー手順案内。
#   第1引数: 保存ファイルのパス (無ければ空文字)
#   第2引数: コピー対象が単一行なら 1
#   SSM_GUIDE=0 で抑制できる。
# ---------------------------------------------------------------
print_sessionmanager_clipboard_guide() {
    local file="$1"
    local single_line="$2"

    [ "$SSM_GUIDE" = "0" ] && return 0

    cat >&2 <<'EOF'

--------------------------------------------------------------------
[Session Manager (ブラウザ) クリップボード案内]
  AWS マネジメントコンソールの Session Manager 端末 (Chrome / Edge) は
  xterm.js ベースで、OSC52 によるリモートからのクリップボード書き込みに
  対応していません。EC2 側から自動でコピーすることは仕組み上できないため、
  上の COPY ブロックから下記の手順でコピーしてください。
EOF

    if [ "$single_line" = "1" ]; then
        cat >&2 <<'EOF'

  ■ コピー手順 (Chrome / Edge 共通)
    1. COPY ブロック内の行を「ダブルクリック」します
       → 画面上で折り返して表示されていても、ひとまとまりとして
         選択されます (行の途中で切れることはありません)
    2. Ctrl + C でコピーします
       ※ Ctrl + C が効かない (SIGINT として送られてしまう) 場合は
         Ctrl + Insert、または選択範囲を右クリックして [コピー] を選択
    3. 貼り付け先のアプリケーションで Ctrl + V で貼り付けます

  ■ うまく選択できない場合
    - 行全体を選ぶ  : COPY ブロック内の行を「トリプルクリック」
    - ドラッグ選択時 : 罫線 (===== の行) を選択範囲に含めないでください
EOF
    else
        cat >&2 <<'EOF'

  ■ コピー手順 (Chrome / Edge 共通)
    1. COPY ブロックの先頭でマウスを押し、末尾までドラッグして選択します
       (罫線 ===== の行は選択範囲に含めないでください)
       ※ 選択したままウィンドウ下端へマウスを動かすと自動スクロールします
    2. Ctrl + C でコピーします
       ※ 効かない場合は Ctrl + Insert、または右クリックして [コピー]
    3. 貼り付け先のアプリケーションで Ctrl + V で貼り付けます

  ■ 画面をスクロールして選択しきれない場合
    terraform plan の出力は長くなりやすく、ブラウザ端末では画面外へ
    流れてしまうことがあります。その場合は下記の保存ファイルから
    取り出すのが確実です。
EOF
    fi

    if [ -n "$file" ]; then
        cat >&2 <<EOF

  ■ 保存ファイルから取り出す場合
      保存先  : ${file}
      再表示  : cat ${file}
      S3 経由 : aws s3 cp ${file} s3://<bucket>/<key>
                aws s3 presign s3://<bucket>/<key>
    ※ 保存が不要なら CLIP_SAVE=0、保存先の変更は CLIP_SAVE_DIR で指定できます。
EOF
    fi

    cat >&2 <<'EOF'

  ■ ローカル端末から `aws ssm start-session` で接続している場合
    本スクリプトは OSC52 も併せて送信しています。その端末が OSC52 に
    対応していれば、すでにクリップボードへコピー済みです。

  この案内が不要な場合は SSM_GUIDE=0 を付けて実行してください。
--------------------------------------------------------------------
EOF
}

# ---------------------------------------------------------------
# Session Manager (ブラウザ) 向けのコピー処理。
#   1. OSC52 も一応送る (ローカル端末経由の SSM 接続ならこれで成功する)
#   2. 選択しやすい形で対象文字列を表示する
#      - 罫線と対象文字列を別の行に分ける
#      - 対象文字列の行にはプロンプトも装飾も ANSI カラーも置かない
#        (plan 出力は -no-color で取得済み)
#      → xterm.js は折り返し行を論理行として扱うため、折り返していても
#        ダブルクリック/トリプルクリックで全体が選択できる
#   3. 同じ内容をファイルに保存し、取り逃した場合の退避先を用意する
# ---------------------------------------------------------------
sessionmanager_copy() {
    local text="$1"
    local file single_line header

    file="$(save_clip_file "$text")" || file=""

    case "$text" in
        *$'\n'*) single_line=0 ;;
        *)       single_line=1 ;;
    esac

    if [ "$single_line" = "1" ]; then
        header='===== ↓↓↓ ここから COPY (下の行をダブルクリック → Ctrl+C) ↓↓↓ ====='
    else
        header='===== ↓↓↓ ここから COPY (罫線の内側をドラッグ選択 → Ctrl+C) ↓↓↓ ====='
    fi

    # ローカル端末から `aws ssm start-session` で入っている場合は
    # OSC52 が通るので併せて送る。画面が乱れる端末では SSM_OSC52=0 で止める。
    [ "$SSM_OSC52" = "0" ] || osc52_emit_quiet "$text"

    # terraform plan 側の出力と混ざって同じ行に載らないよう、
    # 少しだけ待ってから行頭に移動して出力する。
    sleep 0.7
    {
        printf '\n\n'
        printf '%s\n' "$header"
        printf '%s\n' "$text"
        printf '===== ↑↑↑ ここまで COPY ↑↑↑ =====\n'
    } > /dev/tty

    print_sessionmanager_clipboard_guide "$file" "$single_line"
    return 0
}

# ---------------------------------------------------------------
# クリップボードコピー (xclip / wl-copy / OSC52 の順にフォールバック)
#   ※ aws_login_check.sh と同一の仕組み。
# ---------------------------------------------------------------
# OSC52 で端末のクリップボードへ書き込む。
#   base64 は改行を除去して 1 本のシーケンスとして送る (改行が混ざると
#   受信側で途切れる原因になる)。
#   送信データ長が OSC52_BUFFER_LIMIT を超える場合は、受信側 (TeraTerm 等)
#   で切り詰められる恐れがあるため、必要なバッファサイズを添えて警告する。
osc52_copy() {
    local text="$1"
    local b64 osc_len

    b64=$(printf '%s' "$text" | base64 | tr -d '\n')

    # 受信側 OSC バッファが保持する制御文字列長 = "52;c;" (5) + base64 長。
    osc_len=$(( ${#b64} + 5 ))

    if [ "$osc_len" -gt "$OSC52_BUFFER_LIMIT" ]; then
        # 少し余裕を持たせた推奨値 (1.5 倍を 1024 単位に切り上げ)。
        local recommend
        recommend=$(( (osc_len * 3 / 2 + 1023) / 1024 * 1024 ))
        {
            echo ""
            echo ">>> [警告] クリップボードへ送るデータ長 ${osc_len} バイトが"
            echo ">>>        OSC バッファ上限の想定値 ${OSC52_BUFFER_LIMIT} バイトを超えています。"
            echo ">>>        TeraTerm では teraterm.ini の MaxOSCBufferSize (既定 4096) を"
            echo ">>>        超えた分が破棄され、貼り付けが途中で切れます。"
            echo ">>>        → teraterm.ini に MaxOSCBufferSize=${recommend} 以上を設定し、"
            echo ">>>          TeraTerm を再起動してから再実行してください。"
            echo ">>>        (バッファを引き上げ済みなら OSC52_BUFFER_LIMIT=${recommend} を"
            echo ">>>         指定するとこの警告を抑制できます。)"
            echo ""
        } >&2
    fi

    if [ -n "${TMUX:-}" ]; then
        # tmux パススルー形式
        printf '\033Ptmux;\033\033]52;c;%s\a\033\\' "$b64" > /dev/tty
    else
        printf '\033]52;c;%s\a' "$b64" > /dev/tty
    fi

    # OSC52 の書き込みは「投げっぱなし」で成否を受信側から取得できない。
    # TeraTerm はリモートからのクリップボード書き込みが既定で無効なため、
    # 貼り付けできない場合に備え、有効化手順を案内する。
    print_teraterm_clipboard_guide
    return 0
}

copy_to_clipboard() {
    local text="$1"

    # --- 追加: Session Manager (ブラウザ) 経由の場合 -------------------------
    #   ブラウザ端末には X11/Wayland も OSC52 も無いため、専用処理へ回す。
    #   (xclip/xsel が動いても EC2 側のクリップボードに入るだけで意味がない)
    if [ "$(detect_terminal)" = "browser" ] && [ -e /dev/tty ]; then
        CLIP_LAST_MODE="browser"
        sessionmanager_copy "$text"
        return 0
    fi

    # --- 以下は従来どおりの経路 (変更なし) ---------------------------------
    CLIP_LAST_MODE="osc52"

    if [ -n "${DISPLAY:-}" ] && command -v xclip >/dev/null 2>&1; then
        printf '%s' "$text" | xclip -selection clipboard && return 0
    fi
    if [ -n "${DISPLAY:-}" ] && command -v xsel >/dev/null 2>&1; then
        printf '%s' "$text" | xsel --clipboard --input && return 0
    fi
    if [ -n "${WAYLAND_DISPLAY:-}" ] && command -v wl-copy >/dev/null 2>&1; then
        printf '%s' "$text" | wl-copy && return 0
    fi

    # OSC52: SSH 接続元端末のクリップボードへコピー
    if [ -e /dev/tty ]; then
        osc52_copy "$text"
        return 0
    fi

    return 1
}

# ---------------------------------------------------------------
# 他プロジェクトの common.sh を探索して source する。
#   COMMON_SH_PATH が指定されていればそれを最優先で使う。
# ---------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_SH_LOADED=0

load_common_sh() {
    local candidates=()
    [ -n "${COMMON_SH_PATH:-}" ] && candidates+=("$COMMON_SH_PATH")
    candidates+=(
        "${SCRIPT_DIR}/../common/common.sh"
        "${SCRIPT_DIR}/../common.sh"
        "${SCRIPT_DIR}/common/common.sh"
        "${SCRIPT_DIR}/../scripts/common.sh"
    )

    local c
    for c in "${candidates[@]}"; do
        if [ -f "$c" ]; then
            # shellcheck source=/dev/null
            if source "$c"; then
                COMMON_SH_LOADED=1
                echo "=== common.sh を読み込みました: $c"
                return 0
            fi
        fi
    done

    echo "=== common.sh が見つかりませんでした。フォールバック実装でチェックします。" >&2
    echo "    (COMMON_SH_PATH で明示指定できます)" >&2
    return 1
}

# ---------------------------------------------------------------
# common.sh 内の関数名を自動探索するヘルパ。
#   第1引数: 明示指定された関数名 (空可)
#   第2引数以降: 候補となる関数名
#   見つかった関数名を stdout へ返す。見つからなければ空。
# ---------------------------------------------------------------
resolve_func() {
    local explicit="$1"; shift
    if [ -n "$explicit" ]; then
        if declare -F "$explicit" >/dev/null 2>&1; then
            printf '%s' "$explicit"
        fi
        return
    fi
    local name
    for name in "$@"; do
        if declare -F "$name" >/dev/null 2>&1; then
            printf '%s' "$name"
            return
        fi
    done
}

# ---------------------------------------------------------------
# AWS 認証チェック。
#   common.sh の関数があれば委譲 (スイッチバック)、無ければフォールバック。
# ---------------------------------------------------------------
run_aws_auth_check() {
    local fn
    fn=$(resolve_func "${COMMON_AWS_AUTH_FUNC:-}" \
        check_aws_auth check_aws_credentials aws_auth_check \
        check_aws_login check_aws)
    if [ -n "$fn" ]; then
        echo "=== AWS 認証チェックを common.sh:${fn}() に委譲します。"
        "$fn"
        return $?
    fi

    # --- フォールバック実装 ---
    echo "=== AWS 認証チェック (フォールバック): aws sts get-caller-identity"
    aws sts get-caller-identity >/dev/null 2>&1
}

# ---------------------------------------------------------------
# Terraform 実行権限チェック。
#   common.sh の関数があれば委譲 (スイッチバック)、無ければフォールバック。
# ---------------------------------------------------------------
run_terraform_permission_check() {
    local fn
    fn=$(resolve_func "${COMMON_TF_PERM_FUNC:-}" \
        check_terraform_permission check_tf_permission \
        check_terraform check_tf terraform_permission_check)
    if [ -n "$fn" ]; then
        echo "=== Terraform 実行権限チェックを common.sh:${fn}() に委譲します。"
        "$fn"
        return $?
    fi

    # --- フォールバック実装 ---
    #   terraform コマンドの存在と、plan フォルダの初期化状態を確認する。
    echo "=== Terraform 実行権限チェック (フォールバック)"
    if ! command -v terraform >/dev/null 2>&1; then
        echo "    terraform コマンドが見つかりません。" >&2
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------
# plan 出力を「みやすい形式」に整形する。
#   - 見出し (実行日時 / 実行ディレクトリ)
#   - Plan サマリ行 (Plan: X to add, ...) の抽出
#   - 本文 (no-color の plan 出力)
# ---------------------------------------------------------------
format_plan_output() {
    local dir="$1"
    local plan_body="$2"
    local ts summary
    ts="$(date '+%Y-%m-%d %H:%M:%S %Z')"

    # サマリ行の抽出 (無ければ No changes を探す)
    summary=$(printf '%s\n' "$plan_body" \
        | grep -E '^(Plan:|No changes\.|Apply complete)' | tail -n 1)
    [ -z "$summary" ] && summary="(サマリ行を検出できませんでした)"

    printf '%s\n' '========================================'
    printf '%s\n' ' Terraform Plan Result'
    printf '%s\n' '========================================'
    printf ' 実行日時      : %s\n' "$ts"
    printf ' 実行ディレクトリ: %s\n' "$dir"
    printf ' サマリ        : %s\n' "$summary"
    printf '%s\n' '----------------------------------------'
    printf '%s\n' "$plan_body"
    printf '%s\n' '========================================'
}

# ===============================================================
# メイン処理
# ===============================================================
PLAN_DIR="${1:-.}"

if [ ! -d "$PLAN_DIR" ]; then
    echo "=== 指定された plan 実行フォルダが存在しません: $PLAN_DIR" >&2
    exit 1
fi

# common.sh の読み込み (存在しなくてもフォールバックで続行)
load_common_sh || true

# 端末種別を先に判定し、ブラウザ (Session Manager) の場合は
# 自動コピーができない旨を最初に伝えておく。
DETECTED_MODE="$(detect_terminal)"
if [ "$DETECTED_MODE" = "browser" ]; then
    echo ""
    echo "=== Session Manager (ブラウザ) セッションを検出しました。"
    echo "=== ブラウザ端末 (Chrome / Edge) は OSC52 に対応しておらず自動コピーが"
    echo "===   できないため、plan 結果をコピーしやすい形式で表示・保存します。"
    echo "===   (CLIP_MODE=osc52 を指定すると従来どおりの動作に戻せます)"
fi

echo ""
echo "=== [1/3] AWS 認証状態をチェックしています..."
if ! run_aws_auth_check; then
    echo "=== AWS が未認証です。先に aws_login_check.sh などでログインしてください。" >&2
    exit 1
fi
echo "=== AWS 認証 OK"

echo ""
echo "=== [2/3] Terraform 実行権限をチェックしています..."
if ! run_terraform_permission_check; then
    echo "=== Terraform の実行権限チェックに失敗しました。" >&2
    exit 1
fi
echo "=== Terraform 実行権限 OK"

echo ""
echo "=== [3/3] terraform plan を実行しています (dir: $PLAN_DIR)..."

# plan 実行フォルダへ移動して terraform plan を実行。
#   -no-color でクリップボード向けに ANSI カラーを除去する。
#   TF_PLAN_ARGS で追加引数を渡せる。
PLAN_OUT="$(cd "$PLAN_DIR" && terraform plan -no-color ${TF_PLAN_ARGS:-} 2>&1)"
PLAN_STATUS=$?

# 画面には実行結果をそのまま表示する。
printf '%s\n' "$PLAN_OUT"

if [ "$PLAN_STATUS" -ne 0 ]; then
    echo "" >&2
    echo "=== terraform plan が失敗しました (exit code: ${PLAN_STATUS})。クリップボードへはコピーしません。" >&2
    exit "$PLAN_STATUS"
fi

# みやすい形式に整形してクリップボードへコピー。
FORMATTED="$(format_plan_output "$(cd "$PLAN_DIR" && pwd)" "$PLAN_OUT")"

echo ""
if copy_to_clipboard "$FORMATTED"; then
    if [ "$CLIP_LAST_MODE" = "browser" ]; then
        echo "=== 整形した terraform plan 結果を上の COPY ブロックに表示しました。"
        echo "=== 罫線の内側をドラッグ選択して Ctrl+C でコピーしてください。"
        echo "=== (選択しきれない場合は上記の保存ファイルから取り出せます)"
    else
        echo "=== 整形した terraform plan 結果をクリップボードにコピーしました。"
        echo "=== ブラウザやエディタのある端末に貼り付けて確認できます。"
    fi
else
    echo "=== クリップボードへのコピーに失敗しました。上記の出力を手動でコピーしてください。" >&2
    exit 1
fi

exit 0
