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
set -u

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
        local b64
        b64=$(printf '%s' "$text" | base64 | tr -d '\n')
        if [ -n "${TMUX:-}" ]; then
            # tmux パススルー形式
            printf '\033Ptmux;\033\033]52;c;%s\a\033\\' "$b64" > /dev/tty
        else
            printf '\033]52;c;%s\a' "$b64" > /dev/tty
        fi
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
