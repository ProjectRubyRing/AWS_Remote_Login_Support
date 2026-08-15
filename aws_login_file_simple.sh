#!/usr/bin/env bash
#
# aws_login_file_simple.sh
#   aws login --remote を実行し、OAuth URL を *クリップボードにコピーせず*
#   ファイルへ出力して、そのファイルを接続元端末 (TeraTerm) へ
#   ダウンロードするところまでを行うシンプル版。
#
#   トークンの受け渡しはスクリプトでは行わない。aws login はそのまま端末を
#   持ったまま入力待ちになるので、aws_login_check.sh と同じ感覚で、
#   認証後に表示されたトークンをこの画面に貼り付ければ認証が続行される。
#
# 3 つのスクリプトの使い分け:
#   aws_login_check.sh        URL をクリップボード (OSC52 等) へコピーする
#   aws_login_file_simple.sh  URL をファイルへ出力し端末へダウンロードする ← 本スクリプト
#   aws_login_file.sh         上記に加えてトークンの受け渡しまで自動化する
#                             (標準入力を保持し、擬似端末・TeraTerm マクロ連携に対応)
#
# 処理の流れ:
#   EC2 (RHEL9)                                接続元端末 (Windows + TeraTerm)
#   ---------------------------------------    ----------------------------------
#   1. aws sts get-caller-identity で確認
#   2. aws login --remote を起動
#      (端末はそのまま aws login が持つ)
#   3. 出力から OAuth URL を検出
#   4. URL_OUT_DIR にファイルを出力
#   5. sz (ZMODEM) で送信               ──▶   TeraTerm が自動受信し
#                                             FileDir (指定フォルダ) へ保存
#   6. aws login の入力待ちへ戻る              ファイルの URL をブラウザで開いて認証
#                                       ◀──   表示されたトークンを画面に貼り付け
#   7. aws sts get-caller-identity で確認
#
# 使い方:
#   ./aws_login_file_simple.sh
#
#   例:
#     URL_OUT_DIR=~/aws_url ./aws_login_file_simple.sh   # 出力先を指定
#     DOWNLOAD=none ./aws_login_file_simple.sh           # 転送せずファイル出力だけ
#
# 前提:
#   - AWS CLI v2 (aws login コマンド対応バージョン) がインストール済み
#   - プロファイルを使う場合は環境変数 AWS_PROFILE を設定して実行
#   - ダウンロードを使う場合は EC2 側に lrzsz (sz コマンド) が必要
#       sudo dnf install -y lrzsz
#     ※ 入っていない場合は転送を自動的にスキップし、代替手順を案内する。
#
# ★ 接続元端末 (TeraTerm) 側の設定 ★
#   ZMODEM の自動受信と保存先は teraterm.ini でのみ設定できる
#   (「その他の設定」ダイアログには項目が無い)。[Tera Term] セクションに
#   下記を設定して TeraTerm を再起動すること。
#
#       ZmodemAuto=on                 ; ホスト側の sz を検知して自動で受信を開始
#       FileDir=C:\aws_login_url      ; 受信ファイルの保存先 (= ダウンロード先)
#       AutoFileRename=on             ; 同名ファイルがあれば自動でリネーム
#
#   同梱の ec2_auto_login.ttl でログインする場合は、マクロ内の
#   CFG_ZmodemAuto / CFG_FileDir を設定するだけで上記 ini が自動生成される。
#
# ★ 一時停止について ★
#   ZMODEM は端末を双方向に使う。aws login はトークン入力のため端末を
#   読んでいるので、そのまま転送すると受信側 (TeraTerm) が返す応答を
#   aws login が横取りしてしまい、転送が失敗する。
#   そのため本スクリプトは、転送のあいだだけ aws login を一時停止 (SIGSTOP)
#   し、終わったら再開 (SIGCONT) する。停止するのは通常 1 秒未満。
#   ※ 転送が途中で失敗した場合、まれに ZMODEM の残骸が端末の入力に残り、
#     貼り付けたトークンの先頭に混ざることがある。その場合は一度 Enter を
#     押してから、あらためてトークンを貼り付け直してください。
#     (残骸を自動で読み捨てる処理は、貼り付けたトークンを削り取って
#      しまう危険のほうが大きいため、あえて入れていない)
#
# 環境変数 (省略可):
#   [出力ファイル]
#   URL_OUT_DIR      EC2 側の URL ファイル出力先 (既定 ~/aws_login_url)
#   URL_FILE_PREFIX  出力ファイル名の接頭辞 (既定 aws_login_url)
#   URL_FILE_NAME    出力ファイル名を固定したい場合に指定 (既定は接頭辞+日時)
#   URL_LATEST       1 で <接頭辞>-latest.txt も併せて出力する (既定 1)
#   URL_SHORTCUT     1 で Windows のインターネットショートカット (.url) も
#                    出力する。ダブルクリックだけでブラウザが開く (既定 1)
#   URL_FILE_KEEP    1 で認証成功後も出力ファイルを残す (既定 0 = 削除)
#
#   [接続元端末への転送]
#   DOWNLOAD         auto (既定) / zmodem / none
#                      auto   … sz があり端末が ZMODEM を扱える場合のみ転送
#                      zmodem … 常に ZMODEM 転送を試みる
#                      none   … 転送しない (ファイル出力と案内のみ)
#   DOWNLOAD_DIR     接続元端末側の保存先。保存先を決めるのは TeraTerm の
#                    FileDir 設定のため、ここでの指定は画面案内の表示にのみ使う
#   DOWNLOAD_CRLF    1 で転送用コピーの改行を CRLF に変換する (既定 1)
#   ZMODEM_CMD       ZMODEM 送信コマンド (既定 sz)
#   ZMODEM_OPTS      ZMODEM 送信オプション (既定 -b。化ける場合は "-b -e")
#   ZMODEM_TIMEOUT   ZMODEM 送信のタイムアウト秒 (既定 60)
#
#   [aws login]
#   LOGIN_CMD        実行するログインコマンド (既定 "aws login --remote")
#   URL_WAIT         OAuth URL 検出のタイムアウト秒 (既定 90)
#
set -u

# ===============================================================
# 設定
# ===============================================================

# --- EC2 側: URL ファイルの出力 ---
URL_OUT_DIR="${URL_OUT_DIR:-${HOME:-/tmp}/aws_login_url}"
URL_FILE_PREFIX="${URL_FILE_PREFIX:-aws_login_url}"
URL_FILE_NAME="${URL_FILE_NAME:-}"
URL_LATEST="${URL_LATEST:-1}"
URL_SHORTCUT="${URL_SHORTCUT:-1}"
URL_FILE_KEEP="${URL_FILE_KEEP:-0}"

# --- 接続元端末への転送 ---
DOWNLOAD="${DOWNLOAD:-auto}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-}"
DOWNLOAD_CRLF="${DOWNLOAD_CRLF:-1}"
ZMODEM_CMD="${ZMODEM_CMD:-sz}"
ZMODEM_OPTS="${ZMODEM_OPTS:--b}"
ZMODEM_TIMEOUT="${ZMODEM_TIMEOUT:-60}"

# --- aws login ---
LOGIN_CMD="${LOGIN_CMD:-aws login --remote}"
URL_WAIT="${URL_WAIT:-90}"

# ===============================================================
# 内部変数
# ===============================================================
TMP_DIR=""          # 作業用ディレクトリ
TMP_OUT=""          # aws login の出力記録 (URL 検出用)
LOGIN_PID=""        # aws login のプロセス ID
LOGIN_STOPPED=0     # aws login を一時停止中かどうか
TTY_OUT="/dev/stdout"   # 画面出力先 (可能なら /dev/tty)
STTY_SAVED=""       # ZMODEM 送信の前後で退避する端末設定
URL_FILE=""         # 出力した URL ファイル (本体)
URL_FILES=()        # 生成した URL ファイル一式 (転送・後片付け用)
SEND_FILES=()       # ZMODEM で送信するファイル

info() { printf '=== %s\n' "$*"; }
warn() { printf '>>> %s\n' "$*" >&2; }

# ---------------------------------------------------------------
# 後片付け
#   一時停止したまま終わらないよう SIGCONT を送ってから終了させる。
#   ※ 出力した URL ファイルは認証成功時のみ削除する
#     (異常終了時は後から cat できるよう意図的に残す)
# ---------------------------------------------------------------
cleanup() {
    if [ -n "$LOGIN_PID" ]; then
        kill -CONT "$LOGIN_PID" 2>/dev/null
        kill "$LOGIN_PID" 2>/dev/null
    fi
    restore_tty
    exec 8<&- 2>/dev/null
    [ -n "$TMP_DIR" ] && rm -rf "$TMP_DIR"
    return 0
}

restore_tty() {
    if [ -n "$STTY_SAVED" ] && [ -e /dev/tty ]; then
        stty "$STTY_SAVED" < /dev/tty 2>/dev/null
        STTY_SAVED=""
    fi
    return 0
}

# ---------------------------------------------------------------
# 認証済みかどうかのチェック
# ---------------------------------------------------------------
is_authenticated() {
    aws sts get-caller-identity >/dev/null 2>&1
}

# ---------------------------------------------------------------
# Session Manager (ブラウザ端末) かどうかの判定。
#   自プロセスの祖先に SSM のセッションワーカーがいるかどうかで見分ける。
#   ブラウザ端末 (xterm.js) は ZMODEM を扱えないため、DOWNLOAD=auto では
#   転送を試みずに代替手順を案内する。
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
# ZMODEM 転送を行うかどうかの判定。
#   標準出力へ "1" (行う) または "0:<理由>" (行わない) を返す。
# ---------------------------------------------------------------
should_download() {
    case "$DOWNLOAD" in
        none) printf '0:disabled'; return 0 ;;
    esac

    [ -e /dev/tty ] || { printf '0:notty'; return 0; }
    command -v "$ZMODEM_CMD" >/dev/null 2>&1 || { printf '0:nosz'; return 0; }

    # DOWNLOAD=zmodem は明示指定なので、ブラウザ端末判定では止めない
    [ "$DOWNLOAD" = "zmodem" ] && { printf '1'; return 0; }

    has_ssm_ancestor && { printf '0:browser'; return 0; }

    printf '1'
}

# ---------------------------------------------------------------
# ログインプロセスが動作中かどうか。
#   kill -0 はゾンビ (終了済みで未回収) でも成功するため、
#   /proc の State も見て終了済みを取りこぼさないようにする。
# ---------------------------------------------------------------
login_running() {
    [ -n "$LOGIN_PID" ] || return 1
    kill -0 "$LOGIN_PID" 2>/dev/null || return 1
    if [ -r "/proc/${LOGIN_PID}/status" ]; then
        case "$(awk '/^State:/{print $2; exit}' "/proc/${LOGIN_PID}/status" 2>/dev/null)" in
            Z) return 1 ;;
        esac
    fi
    return 0
}

# ---------------------------------------------------------------
# OAuth URL の抽出。出力から最初の https:// URL を取り出す。
#   CR や ANSI エスケープが混ざる場合に備えて先に取り除く。
# ---------------------------------------------------------------
extract_url() {
    [ -s "$TMP_OUT" ] || return 0
    tr '\r' '\n' < "$TMP_OUT" 2>/dev/null \
        | sed -e 's/\x1b\[[0-9;?]*[A-Za-z]//g' \
        | grep -oE 'https://[^[:space:]"'"'"'<>|]+' \
        | head -n 1 \
        | sed -e 's/[.,;:)]*$//'
}

# ---------------------------------------------------------------
# OAuth URL が出力されるまで待つ。検出できたら標準出力へ URL を返す。
#   書き込み途中を拾って URL が欠けるのを避けるため、2 回続けて同じ値が
#   取れたことを確認してから確定する。
# ---------------------------------------------------------------
wait_for_url() {
    local deadline=$((SECONDS + URL_WAIT))
    local url prev="" alive=1

    while [ "$SECONDS" -lt "$deadline" ]; do
        url="$(extract_url)"
        if [ -n "$url" ] && [ "$url" = "$prev" ]; then
            printf '%s' "$url"
            return 0
        fi
        prev="$url"

        # URL を出さずに終了した場合は、最後にもう一度だけ確認して諦める
        if ! login_running; then
            if [ "$alive" = "0" ]; then
                url="$(extract_url)"
                [ -n "$url" ] && { printf '%s' "$url"; return 0; }
                return 1
            fi
            alive=0
        fi

        sleep 0.4
    done
    return 1
}

# ---------------------------------------------------------------
# URL ファイルの出力。
#   生成したファイルのパスをグローバル変数へ入れる。
#     URL_FILE  … 本体 (URL を 1 行だけ書いたファイル)
#     URL_FILES … 生成した全ファイル (転送・後片付け用)
#   URL は一度きりの認証情報を含むため、パーミッションは 600 とする。
# ---------------------------------------------------------------
write_url_files() {
    local url="$1"
    local stamp base main latest shortcut

    mkdir -p "$URL_OUT_DIR" 2>/dev/null || return 1
    chmod 700 "$URL_OUT_DIR" 2>/dev/null

    if [ -n "$URL_FILE_NAME" ]; then
        base="$URL_FILE_NAME"
    else
        stamp="$(date '+%Y%m%d-%H%M%S')"
        base="${URL_FILE_PREFIX}-${stamp}.txt"
    fi
    main="${URL_OUT_DIR}/${base}"

    # 中身は URL 1 行のみ。開いてそのままコピー/貼り付けできるようにする。
    ( umask 077; printf '%s\n' "$url" > "$main" ) || return 1
    URL_FILES+=("$main")

    if [ "$URL_LATEST" = "1" ]; then
        latest="${URL_OUT_DIR}/${URL_FILE_PREFIX}-latest.txt"
        ( umask 077; printf '%s\n' "$url" > "$latest" ) 2>/dev/null \
            && URL_FILES+=("$latest")
    fi

    # Windows のインターネットショートカット。ダブルクリックでブラウザが開く。
    if [ "$URL_SHORTCUT" = "1" ]; then
        shortcut="${main%.txt}.url"
        (
            umask 077
            printf '[InternetShortcut]\r\n' > "$shortcut"
            printf 'URL=%s\r\n' "$url" >> "$shortcut"
        ) 2>/dev/null && URL_FILES+=("$shortcut")
    fi

    URL_FILE="$main"
    return 0
}

# ---------------------------------------------------------------
# 転送用コピーの作成。作成したファイルのパスを SEND_FILES へ入れる。
#   接続元端末は Windows 想定のため、既定では改行を CRLF に変換した
#   コピーを転送する (EC2 側に残るファイルは LF のまま)。
#   .url は元から CRLF、-latest.txt は重複なので転送しない。
# ---------------------------------------------------------------
make_send_files() {
    local send_dir="${TMP_DIR}/send"
    local f name dst

    SEND_FILES=()
    mkdir -p "$send_dir" || return 1

    for f in "${URL_FILES[@]}"; do
        name="$(basename "$f")"
        case "$name" in
            "${URL_FILE_PREFIX}-latest.txt") continue ;;
        esac
        dst="${send_dir}/${name}"
        case "$name" in
            *.url)
                cp -f "$f" "$dst" || return 1
                ;;
            *)
                if [ "$DOWNLOAD_CRLF" = "1" ]; then
                    sed -e 's/$/\r/' "$f" > "$dst" || return 1
                else
                    cp -f "$f" "$dst" || return 1
                fi
                ;;
        esac
        SEND_FILES+=("$dst")
    done
    return 0
}

# ---------------------------------------------------------------
# aws login の一時停止と再開。
#   ZMODEM は端末を双方向に使うため、転送中に aws login が端末を読んで
#   いると受信側の応答を横取りされて転送が壊れる。転送のあいだだけ止める。
# ---------------------------------------------------------------
suspend_login() {
    login_running || return 1
    kill -STOP "$LOGIN_PID" 2>/dev/null || return 1
    LOGIN_STOPPED=1
    # 停止が反映されるまで少しだけ待つ
    sleep 0.2
    return 0
}

resume_login() {
    [ "$LOGIN_STOPPED" = "1" ] || return 0
    kill -CONT "$LOGIN_PID" 2>/dev/null
    LOGIN_STOPPED=0
    return 0
}

# ---------------------------------------------------------------
# ZMODEM (sz) で接続元端末へ送信する。
#   進捗メッセージ (stderr) は画面ではなくログへ逃がす。同じ端末に出すと
#   ZMODEM のデータ列を壊すおそれがあるため。
# ---------------------------------------------------------------
zmodem_send() {
    local files=("$@")
    local rc=0
    local sz_err="${TMP_DIR}/sz.err"

    command -v "$ZMODEM_CMD" >/dev/null 2>&1 || return 127
    [ -e /dev/tty ] || return 1

    STTY_SAVED="$(stty -g < /dev/tty 2>/dev/null)" || STTY_SAVED=""

    # aws login 側の出力を吐き切らせてから始める
    sleep 0.5

    # ZMODEM_OPTS は複数オプションを渡せるよう、意図的にクォートしない
    if command -v timeout >/dev/null 2>&1; then
        # shellcheck disable=SC2086
        timeout "$ZMODEM_TIMEOUT" "$ZMODEM_CMD" $ZMODEM_OPTS "${files[@]}" \
            < /dev/tty > /dev/tty 2>"$sz_err"
        rc=$?
    else
        # shellcheck disable=SC2086
        "$ZMODEM_CMD" $ZMODEM_OPTS "${files[@]}" \
            < /dev/tty > /dev/tty 2>"$sz_err"
        rc=$?
    fi

    if [ "$rc" -ne 0 ]; then
        # ZMODEM キャンセル (CAN x8 + BS x8)。受信待ちのままになるのを防ぐ。
        printf '\030\030\030\030\030\030\030\030\010\010\010\010\010\010\010\010' \
            > /dev/tty 2>/dev/null
        sleep 0.3
    fi

    restore_tty

    if [ "$rc" -ne 0 ] && [ -s "$sz_err" ]; then
        {
            echo ""
            echo ">>> [sz の出力]"
            sed -e 's/^/>>>   /' "$sz_err" | tail -n 10
        } >&2
    fi

    return "$rc"
}

# ---------------------------------------------------------------
# 転送が使えない/失敗した場合の代替手順の案内。
#   第1引数: URL ファイルのパス / 第2引数: 理由
# ---------------------------------------------------------------
print_download_guide() {
    local file="$1"
    local reason="$2"

    {
        echo ""
        echo "--------------------------------------------------------------------"
        echo "[接続元端末へのファイル転送について]"
        case "$reason" in
            nosz)
                echo "  ZMODEM 送信コマンド (${ZMODEM_CMD}) が見つからないため、自動ダウンロードを"
                echo "  行いませんでした。次のコマンドで導入できます。"
                echo "      sudo dnf install -y lrzsz"
                ;;
            browser)
                echo "  Session Manager (ブラウザ) セッションを検出しました。ブラウザ端末は"
                echo "  ZMODEM に対応していないため、自動ダウンロードを行いませんでした。"
                ;;
            disabled)
                echo "  DOWNLOAD=${DOWNLOAD} が指定されているため、自動ダウンロードを行いません。"
                ;;
            notty)
                echo "  端末 (/dev/tty) を利用できないため、自動ダウンロードを行いませんでした。"
                ;;
            *)
                echo "  ZMODEM による自動ダウンロードに失敗しました。TeraTerm 側で ZMODEM の"
                echo "  自動受信が無効になっている可能性があります。"
                ;;
        esac
        echo ""
        echo "  ■ EC2 側の URL ファイル"
        echo "      ${file}"
        echo "      表示   : cat ${file}"
        echo ""
        echo "  ■ 手動でダウンロードする方法"
        echo "    (a) [ファイル] - [SSH SCP...] を開き、Receive 欄に上記パスを入力する"
        echo "    (b) [ファイル] - [転送] - [ZMODEM] - [受信] を選んでから、EC2 側で"
        echo "        次を実行する"
        echo "            sz ${file}"
        echo ""
        echo "  ■ ZMODEM の自動受信を有効にする (推奨)"
        echo "      teraterm.ini の [Tera Term] セクションに次を設定し、TeraTerm を"
        echo "      再起動してください (「その他の設定」ダイアログには項目がありません)。"
        echo "          ZmodemAuto=on"
        echo "          FileDir=<ダウンロード先フォルダ>"
        echo "      ※ ec2_auto_login.ttl でログインしている場合は、マクロ内の"
        echo "        CFG_ZmodemAuto / CFG_FileDir を設定すれば ini が自動生成されます。"
        echo "--------------------------------------------------------------------"
        echo ""
    } >&2
}

# ===============================================================
# メイン処理
# ===============================================================

info "AWS 認証状態をチェックしています..."

if is_authenticated; then
    identity=$(aws sts get-caller-identity --output text --query 'Arn' 2>/dev/null)
    info "認証済みです: ${identity}"
    exit 0
fi

info "未認証です。${LOGIN_CMD} を実行します。"

[ -e /dev/tty ] && TTY_OUT="/dev/tty"

TMP_DIR="$(mktemp -d /tmp/aws_login_file_simple.XXXXXX)" || {
    warn "作業用ディレクトリを作成できませんでした。"
    exit 1
}
TMP_OUT="${TMP_DIR}/login_output.log"
: > "$TMP_OUT"
trap cleanup EXIT

DL_DECISION="$(should_download)"
DO_DOWNLOAD="${DL_DECISION%%:*}"
DL_REASON="${DL_DECISION#*:}"
[ "$DL_REASON" = "$DL_DECISION" ] && DL_REASON=""

if [ "$DO_DOWNLOAD" = "1" ]; then
    info "OAuth URL をファイルへ出力し、ZMODEM で接続元端末へ転送します。"
else
    info "OAuth URL をファイルへ出力します (自動ダウンロードは行いません)。"
fi
echo ""

# aws login へ渡す標準入力 (fd 8) を用意する。
#   ジョブ制御の無いシェルでバックグラウンド実行すると、子プロセスの標準入力は
#   自動的に /dev/null へ差し替えられる (POSIX の規定)。そのままだとトークンを
#   入力できないため、端末を明示的に渡す。端末が使えない場合はスクリプトの
#   標準入力をそのまま引き継ぐ。
if (exec 8</dev/tty) 2>/dev/null; then
    exec 8</dev/tty
else
    exec 8<&0
fi

# aws login をバックグラウンドで起動する。
#   - 標準入力は端末 (fd 8)。トークンは aws login が直接受け取る
#   - 出力はプロセス置換の tee で画面と記録ファイルへ分ける
#   - プロセス置換にすると $! が aws login 自身の PID になり、
#     転送中の一時停止 (SIGSTOP) と終了コードの取得ができる
# ※ ジョブ制御の無いスクリプトでは、バックグラウンドの子プロセスも
#   スクリプトと同じプロセスグループ (= 端末のフォアグラウンド) なので、
#   端末からの入力をそのまま読める。
eval "$LOGIN_CMD" <&8 8<&- > >(tee "$TMP_OUT" > "$TTY_OUT") 2>&1 &
LOGIN_PID=$!

# --- OAuth URL の検出 ---
url="$(wait_for_url)" || url=""
if [ -z "$url" ]; then
    echo ""
    warn "OAuth URL を検出できませんでした (${URL_WAIT} 秒待機)。"
    if [ -s "$TMP_OUT" ]; then
        {
            echo ">>> [${LOGIN_CMD} の出力 (末尾)]"
            tr '\r' '\n' < "$TMP_OUT" | tail -n 15 | sed -e 's/^/>>>   /'
        } >&2
    fi
    exit 1
fi

# --- URL ファイルの出力 ---
if ! write_url_files "$url" || [ -z "$URL_FILE" ]; then
    warn "URL ファイルを出力できませんでした (出力先: ${URL_OUT_DIR})。"
    exit 1
fi
url_file="$URL_FILE"

echo ""
info "OAuth URL をファイルへ出力しました。"
info "  出力先: ${url_file}"

# --- 接続元端末への転送 ---
downloaded=0
if [ "$DO_DOWNLOAD" = "1" ]; then
    if ! make_send_files || [ "${#SEND_FILES[@]}" -eq 0 ]; then
        warn "転送用ファイルを準備できませんでした。"
        print_download_guide "$url_file" "failed"
    else
        info "ZMODEM で送信します (受信は TeraTerm が自動で開始します)..."

        # 転送中だけ aws login を止めて、端末を独占する
        suspend_login
        zmodem_send "${SEND_FILES[@]}"
        zmodem_status=$?
        resume_login

        if [ "$zmodem_status" -eq 0 ]; then
            downloaded=1
            echo ""
            info "接続元端末へのダウンロードが完了しました。"
            if [ -n "$DOWNLOAD_DIR" ]; then
                info "  保存先: ${DOWNLOAD_DIR} (TeraTerm の FileDir 設定に従います)"
            else
                info "  保存先: TeraTerm の FileDir に設定したフォルダ"
            fi
            info "  ファイル名: $(basename "$url_file")"
            if [ "$URL_SHORTCUT" = "1" ]; then
                info "  ${URL_FILE_PREFIX}-*.url をダブルクリックすると既定のブラウザで開きます"
            fi
        elif [ "$zmodem_status" -eq 127 ]; then
            print_download_guide "$url_file" "nosz"
        else
            print_download_guide "$url_file" "failed"
        fi
    fi
else
    print_download_guide "$url_file" "${DL_REASON:-disabled}"
fi

# --- あとは aws login の入力待ちに任せる ---
{
    echo ""
    echo "--------------------------------------------------------------------"
    if [ "$downloaded" = "1" ]; then
        echo ">>> ダウンロードしたファイルの URL をブラウザで開いて認証してください。"
    else
        echo ">>> 上記ファイルの URL をブラウザで開いて認証してください。"
    fi
    echo ">>> 認証後に表示されたトークンを、この画面に貼り付けて Enter を押すと"
    echo ">>> ${LOGIN_CMD} が認証を続行します。"
    echo "--------------------------------------------------------------------"
    echo ""
} > "$TTY_OUT"

# aws login の終了を待つ (トークンの入力は aws login が直接受け取る)
wait "$LOGIN_PID" 2>/dev/null
login_status=$?
LOGIN_PID=""

echo ""
if [ "$login_status" -eq 0 ] && is_authenticated; then
    identity=$(aws sts get-caller-identity --output text --query 'Arn' 2>/dev/null)
    info "ログインに成功しました: ${identity}"

    # URL は一度きりの認証情報を含むため、既定では認証後に削除する
    if [ "$URL_FILE_KEEP" = "0" ] && [ "${#URL_FILES[@]}" -gt 0 ]; then
        rm -f "${URL_FILES[@]}" 2>/dev/null
        info "EC2 側の URL ファイルを削除しました (残す場合は URL_FILE_KEEP=1)。"
    else
        info "EC2 側の URL ファイルを残しました: ${url_file}"
    fi
    if [ "$downloaded" = "1" ]; then
        info "接続元端末にダウンロードしたファイルは不要になりました。削除を推奨します。"
    fi
    exit 0
else
    warn "ログインに失敗しました (exit code: ${login_status})。"
    warn "URL ファイルは残してあります: ${url_file}"
    exit 1
fi
