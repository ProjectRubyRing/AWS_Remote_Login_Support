#!/usr/bin/env bash
#
# aws_login_check.sh
#   EC2 (RHEL9) 上で AWS CLI の認証状態をチェックし、未認証なら
#   `aws login --remote` を実行して OAuth URL をクリップバードにコピーし、
#   トークン貼り付け待ち状態で待機するスクリプト。
#
# 前提:
#   - AWS CLI v2 (aws login コマンド対応バージョン) がインストール済み
#   - プロファイルを使う場合は環境変数 AWS_PROFILE を設定して実行
#
# クリップボードについて:
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
#       MaxOSCBufferSize (既定 4096 バイト) までしかバッファリングせず、超えた分は
#       破棄する。長い文字列は base64 化すると 4096 バイトを超えやすい。
#       → 対策: teraterm.ini で MaxOSCBufferSize=1000000 等に設定し TeraTerm を再起動。
#       本スクリプトは OSC52 データ長を計算し、上限超過時に推奨値付きで警告する。
#       想定バッファ上限は環境変数 OSC52_BUFFER_LIMIT で上書き可能 (既定 4096)。
#
set -u

# OSC バッファ上限 (バイト)。これを超える OSC52 データは受信側で切り詰められる
# 可能性があるため、事前に警告する。TeraTerm 側で MaxOSCBufferSize を引き上げて
# いる場合は、この変数にも同じ値を設定すると不要な警告を抑制できる。
OSC52_BUFFER_LIMIT="${OSC52_BUFFER_LIMIT:-4096}"

TMP_OUT="$(mktemp /tmp/aws_login_out.XXXXXX)"
WATCHER_PID=""

cleanup() {
    [ -n "$WATCHER_PID" ] && kill "$WATCHER_PID" 2>/dev/null
    rm -f "$TMP_OUT"
}
trap cleanup EXIT

# ---------------------------------------------------------------
# 認証済みかどうかのチェック
#   有効な認証情報があれば sts get-caller-identity が成功する
# ---------------------------------------------------------------
is_authenticated() {
    aws sts get-caller-identity >/dev/null 2>&1
}

# ---------------------------------------------------------------
# クリップボードコピー (xclip / wl-copy / OSC52 の順にフォールバック)
# ---------------------------------------------------------------
# OSC52 で端末のクリップボードへ書き込む。
#   base64 は改行を除去して 1 本のシーケンスとして送る。
#   送信データ長が OSC52_BUFFER_LIMIT を超える場合は、受信側 (TeraTerm 等) で
#   切り詰められる恐れがあるため、必要なバッファサイズを添えて警告する。
osc52_copy() {
    local text="$1"
    local b64 osc_len

    b64=$(printf '%s' "$text" | base64 | tr -d '\n')

    # 受信側 OSC バッファが保持する制御文字列長 = "52;c;" (5) + base64 長。
    osc_len=$(( ${#b64} + 5 ))

    if [ "$osc_len" -gt "$OSC52_BUFFER_LIMIT" ]; then
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
            echo ""
        } >&2
    fi

    if [ -n "${TMUX:-}" ]; then
        # tmux パススルー形式
        printf '\033Ptmux;\033\033]52;c;%s\a\033\\' "$b64" > /dev/tty
    else
        printf '\033]52;c;%s\a' "$b64" > /dev/tty
    fi
    return 0
}

copy_to_clipboard() {
    local text="$1"

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
# メイン処理
# ---------------------------------------------------------------
echo "=== AWS 認証状態をチェックしています..."

if is_authenticated; then
    identity=$(aws sts get-caller-identity --output text --query 'Arn' 2>/dev/null)
    echo "=== 認証済みです: ${identity}"
    exit 0
fi

echo "=== 未認証です。aws login --remote を実行します。"
echo "=== OAuth URL が表示され次第、クリップボードへ自動コピーします。"
echo ""

# バックグラウンドで aws login の出力を監視し、
# 最初に現れた URL をクリップボードへコピーする
(
    for _ in $(seq 1 120); do  # 最大 60 秒監視
        url=$(grep -oE 'https://[^[:space:]]+' "$TMP_OUT" 2>/dev/null | head -n 1)
        if [ -n "$url" ]; then
            if copy_to_clipboard "$url"; then
                printf '\n>>> OAuth URL をクリップボードにコピーしました。\n>>> ブラウザのある端末で貼り付けて認証し、表示されたトークンをこの画面に貼り付けてください。\n\n' > /dev/tty
            else
                printf '\n>>> クリップボードへのコピーに失敗しました。上記 URL を手動でコピーしてください。\n\n' > /dev/tty
            fi
            exit 0
        fi
        sleep 0.5
    done
) &
WATCHER_PID=$!

# aws login --remote をフォアグラウンドで実行。
# stdout/stderr は tee 経由で画面表示しつつ TMP_OUT に記録し、
# stdin は端末につないだままにするので、そのままトークンの
# 貼り付け待ち (login remote の続きの処理) が行える。
aws login --remote 2>&1 | tee "$TMP_OUT"
login_status=${PIPESTATUS[0]}

kill "$WATCHER_PID" 2>/dev/null
wait "$WATCHER_PID" 2>/dev/null
WATCHER_PID=""

echo ""
if [ "$login_status" -eq 0 ] && is_authenticated; then
    identity=$(aws sts get-caller-identity --output text --query 'Arn' 2>/dev/null)
    echo "=== ログインに成功しました: ${identity}"
    exit 0
else
    echo "=== ログインに失敗しました (exit code: ${login_status})。" >&2
    exit 1
fi
