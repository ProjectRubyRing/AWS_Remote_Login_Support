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
set -u

# ---------------------------------------------------------------
# クリップボードコピー (xclip / wl-copy / OSC52 の順にフォールバック)
#   ※ aws_login_check.sh と同一の仕組み。
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
    echo "=== 整形した terraform plan 結果をクリップボードにコピーしました。"
    echo "=== ブラウザやエディタのある端末に貼り付けて確認できます。"
else
    echo "=== クリップボードへのコピーに失敗しました。上記の出力を手動でコピーしてください。" >&2
    exit 1
fi

exit 0
