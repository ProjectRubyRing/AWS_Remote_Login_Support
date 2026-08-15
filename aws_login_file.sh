#!/usr/bin/env bash
#
# aws_login_file.sh
#   aws_login_check.sh と同じ「AWS 認証チェック → aws login --remote」を行うが、
#   OAuth URL を *クリップボードにはコピーせず*、EC2 上のファイルへ出力し、
#   そのファイルを接続元端末 (TeraTerm) へ転送 (自動ダウンロード) するスクリプト。
#
#   接続元端末に届いたファイルの URL をブラウザで開いて認証し、表示された
#   トークンをこの画面に貼り付けると、本スクリプトがそれを aws login へ
#   引き渡して認証を続行する。
#
#   aws_login_check.sh との違い:
#     - クリップボード (xclip / wl-copy / OSC52) は一切使わない。
#       → TeraTerm の MaxOSCBufferSize / ClipboardAccessFromRemote に依存しない。
#     - OAuth URL をファイルへ出力し、ZMODEM (sz) で接続元端末へ転送する。
#     - aws login の標準入力を本スクリプトが握り、端末から受け取ったトークンを
#       中継する (ファイル転送中に aws login が端末入力を横取りしないようにするため)。
#
# 3 つのスクリプトの使い分け:
#   aws_login_check.sh        URL をクリップボード (OSC52 等) へコピーする
#   aws_login_file_simple.sh  URL をファイルへ出力し端末へダウンロードするだけ。
#                             トークンは aws login が端末で直接受け取る (シンプル版)
#   aws_login_file.sh         上記に加えてトークンの受け渡しまで自動化する ← 本スクリプト
#                             (標準入力を保持し、擬似端末・TeraTerm マクロ連携に対応)
#
# 処理の流れ:
#   EC2 (RHEL9)                                接続元端末 (Windows + TeraTerm)
#   ---------------------------------------    ----------------------------------
#   1. aws sts get-caller-identity で確認
#   2. aws login --remote を起動
#      (標準入力は本スクリプトが保持)
#   3. 出力から OAuth URL を検出
#   4. URL_OUT_DIR にファイルを出力
#   5. sz (ZMODEM) で送信               ──▶   TeraTerm が自動受信し
#                                             FileDir (指定ディレクトリ) へ保存
#   6. トークン入力待ち                        ファイルの URL をブラウザで開いて認証
#                                       ◀──   表示されたトークンを端末に貼り付け
#   7. 受け取ったトークンを aws login へ
#      中継して認証を続行
#   8. aws sts get-caller-identity で確認
#
# 使い方:
#   ./aws_login_file.sh
#
#   例:
#     # 出力先とダウンロード先を指定して実行
#     URL_OUT_DIR=~/aws_url DOWNLOAD_DIR='C:\aws_login_url' ./aws_login_file.sh
#     # ZMODEM 転送はせず、ファイル出力だけ行う (TeraTerm マクロ側で取得する場合)
#     DOWNLOAD=none ./aws_login_file.sh
#
# 前提:
#   - AWS CLI v2 (aws login コマンド対応バージョン) がインストール済み
#   - プロファイルを使う場合は環境変数 AWS_PROFILE を設定して実行
#   - ZMODEM 転送を使う場合は EC2 側に lrzsz (sz コマンド) が必要
#       sudo dnf install -y lrzsz
#     ※ 入っていない場合は転送を自動的にスキップし、代替手順を案内する。
#
# ★ 接続元端末 (TeraTerm) 側の設定 ★
#   ZMODEM の自動受信と保存先ディレクトリは TeraTerm の ini でのみ設定できる
#   (「その他の設定」ダイアログには項目が無い)。teraterm.ini の [Tera Term]
#   セクションに以下を設定して TeraTerm を再起動すること。
#
#       ZmodemAuto=on                 ; ホスト側の sz を検知して自動で受信を開始
#       FileDir=C:\aws_login_url      ; 受信ファイルの保存先 (= ダウンロード先)
#       AutoFileRename=on             ; 同名ファイルがあれば自動でリネーム
#
#   同梱の ec2_auto_login.ttl でログインする場合は、マクロ内の
#   CFG_ZmodemAuto / CFG_FileDir を書き換えるだけで上記 ini が自動生成される
#   (保存先フォルダもマクロが自動作成する)。
#
#   ZMODEM を使わず TeraTerm マクロ (SCP) でダウンロードする場合は、同梱の
#   aws_login_file_download.ttl を使うと保存先を任意のフォルダに指定できる。
#   その場合、本スクリプトは DOWNLOAD=none で起動される。
#
# TeraTerm マクロ連携用の目印行:
#   マクロ側が waitregex で拾えるよう、以下の行を画面へ出力する。
#     [AWS_LOGIN_FILE] PATH=<URL ファイルの絶対パス>
#     [AWS_LOGIN_FILE] DOWNLOAD=ok|ng        (ZMODEM 転送の結果)
#     [AWS_LOGIN_FILE] TOKEN_WAIT            (トークン入力待ちに入った)
#     [AWS_LOGIN_FILE] DONE=ok|ng|skipped    (最終結果)
#   ※ 目印行は続けて出力されるため、マクロ側で 1 行ずつ待ち受けると
#     取りこぼす可能性がある。マクロは PATH= だけを待ち、ファイル名や
#     .url ファイルのパスは自身で組み立てる作りにしている。
#
# 環境変数 (省略可):
#   [出力ファイル]
#   URL_OUT_DIR      EC2 側の URL ファイル出力先ディレクトリ
#                    (既定 ~/aws_login_url)
#   URL_FILE_PREFIX  出力ファイル名の接頭辞 (既定 aws_login_url)
#   URL_FILE_NAME    出力ファイル名を固定したい場合に指定 (既定は接頭辞+日時)
#   URL_LATEST       1 で <接頭辞>-latest.txt も併せて出力する (既定 1)
#   URL_SHORTCUT     1 で Windows のインターネットショートカット (.url) も
#                    出力する。ダブルクリックだけでブラウザが開く (既定 1)
#   URL_FILE_KEEP    1 で認証成功後も出力ファイルを残す (既定 0 = 削除)
#
#   [接続元端末への転送]
#   DOWNLOAD         auto (既定) / zmodem / none / macro
#                      auto   … sz があり端末が ZMODEM を扱える場合のみ転送
#                      zmodem … 常に ZMODEM 転送を試みる
#                      none   … 転送しない (代替手順を案内する)
#                      macro  … 転送しない (TeraTerm マクロが SCP で取得する。
#                               aws_login_file_download.ttl が指定してくる)
#   DOWNLOAD_DIR     接続元端末側の保存先。ZMODEM の保存先を決めるのは
#                    TeraTerm の FileDir 設定であるため、ここでの指定は
#                    画面案内の表示にのみ使う (既定は空 = TeraTerm の設定に従う)
#   DOWNLOAD_CRLF    1 で転送用コピーの改行を CRLF に変換する (既定 1)
#   ZMODEM_CMD       ZMODEM 送信コマンド (既定 sz)
#   ZMODEM_OPTS      ZMODEM 送信オプション (既定 -b。文字化けする場合は "-b -e")
#   ZMODEM_TIMEOUT   ZMODEM 送信のタイムアウト秒 (既定 60)
#
#   [aws login]
#   LOGIN_CMD        実行するログインコマンド (既定 "aws login --remote")
#   LOGIN_PTY        auto (既定) / 1 / 0
#                    1 なら script(1) で擬似端末を割り当てて aws login を起動する。
#                    標準入力をパイプにすると対話プロンプトを出さない CLI への対策。
#                    auto は script コマンドがあれば 1 とみなす。
#   URL_WAIT         OAuth URL 検出のタイムアウト秒 (既定 90)
#   LOGIN_WAIT       トークン入力後、認証完了を待つ最大秒数 (既定 300)
#   RELAY_ECHO       1 で端末のローカルエコーを止めない (既定 auto)
#                    擬似端末モードでは二重表示を避けるため既定でエコーを止める。
#   PTY_COLS         擬似端末の桁数 (既定 512)。URL が折り返されて欠けるのを
#   PTY_ROWS         防ぐため、既定で広めに設定する。行数の既定は 60。
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
LOGIN_PTY="${LOGIN_PTY:-auto}"
URL_WAIT="${URL_WAIT:-90}"
LOGIN_WAIT="${LOGIN_WAIT:-300}"
RELAY_ECHO="${RELAY_ECHO:-auto}"
PTY_COLS="${PTY_COLS:-512}"
PTY_ROWS="${PTY_ROWS:-60}"

# TeraTerm マクロ (aws_login_file_download.ttl) が待ち受ける目印。
# 画面に出す行の先頭に付けることで、マクロ側から waitregex で拾える。
MARKER="[AWS_LOGIN_FILE]"

# ===============================================================
# 内部変数
# ===============================================================
TMP_DIR=""          # 作業用ディレクトリ
TMP_OUT=""          # aws login の出力記録 (URL 検出用)
FIFO=""             # aws login の標準入力に渡す名前付きパイプ
LOGIN_PID=""        # aws login (または script) のプロセス ID
USE_PTY=0           # 擬似端末を使ったかどうか
TTY_OUT="/dev/stdout"   # 画面出力先 (可能なら /dev/tty)
STTY_SAVED=""       # 端末設定の退避 (エコー制御・ZMODEM 送信の前後で使う)
URL_FILE=""         # 出力した URL ファイル (本体)
URL_FILES=()        # 生成した URL ファイル一式 (転送・後片付け用)
SEND_FILES=()       # ZMODEM で送信するファイル

# ---------------------------------------------------------------
# 画面出力のヘルパ
#   info … 通常メッセージ / warn … 警告 / marker … マクロ向けの目印行
# ---------------------------------------------------------------
info() { printf '=== %s\n' "$*"; }
warn() { printf '>>> %s\n' "$*" >&2; }
marker() { printf '%s %s\n' "$MARKER" "$*"; }

# ---------------------------------------------------------------
# 後片付け
#   - aws login が残っていれば終了させる
#   - 端末設定 (エコー) を元に戻す
#   - 作業用ディレクトリを削除する
#   ※ 出力した URL ファイルは、認証成功時のみ main 側で削除する
#      (異常終了時は後から cat できるよう意図的に残す)
# ---------------------------------------------------------------
cleanup() {
    if [ -n "$LOGIN_PID" ]; then
        kill "$LOGIN_PID" 2>/dev/null
    fi
    restore_tty
    exec 9>&- 2>/dev/null
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
#   有効な認証情報があれば sts get-caller-identity が成功する
# ---------------------------------------------------------------
is_authenticated() {
    aws sts get-caller-identity >/dev/null 2>&1
}

# ---------------------------------------------------------------
# Session Manager (ブラウザ端末) かどうかの判定。
#   aws_login_check.sh と同じ考え方で、自プロセスの祖先に SSM の
#   セッションワーカーがいるかどうかを調べる。
#     amazon-ssm-agent → ssm-agent-worker → ssm-session-worker → shell
#   ブラウザ端末 (xterm.js) は ZMODEM を扱えないため、DOWNLOAD=auto の
#   ときは転送を試みずに代替手順を案内する。
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
#   理由は print_download_guide() の引数にそのまま渡す。
# ---------------------------------------------------------------
should_download() {
    case "$DOWNLOAD" in
        none)   printf '0:disabled'; return 0 ;;
        macro)  printf '0:macro';    return 0 ;;
    esac

    # 端末が無ければ ZMODEM のやり取りができない
    if [ ! -e /dev/tty ]; then printf '0:notty'; return 0; fi

    # DOWNLOAD=zmodem は明示指定なので、ブラウザ端末判定では止めない
    if [ "$DOWNLOAD" = "zmodem" ]; then
        command -v "$ZMODEM_CMD" >/dev/null 2>&1 || { printf '0:nosz'; return 0; }
        printf '1'
        return 0
    fi

    # auto: sz が無い / ブラウザ端末 のいずれかなら行わない
    command -v "$ZMODEM_CMD" >/dev/null 2>&1 || { printf '0:nosz'; return 0; }
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
# OAuth URL の抽出。
#   aws login の出力から最初の https:// URL を取り出す。
#   擬似端末経由の記録には CR や ANSI エスケープが混ざるため、先に取り除く。
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
#   出力の書き込み途中を拾って URL が欠けるのを避けるため、
#   2 回続けて同じ値が取れたことを確認してから確定する。
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

        # ログインプロセスが URL を出さずに終了した場合は、最後にもう一度だけ
        # 出力を確認してから諦める (終了直前の出力を取りこぼさないため)。
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
# aws login の起動。
#   標準入力を名前付きパイプにして本スクリプト側 (fd 9) から書き込めるようにする。
#   こうしておくと、ZMODEM 転送中に aws login が端末入力を横取りしない。
#
#   LOGIN_PTY が有効な場合は script(1) で擬似端末を割り当てる。
#   標準入力がパイプだと対話プロンプトを出さない CLI があるための対策。
# ---------------------------------------------------------------
start_login() {
    mkfifo -m 600 "$FIFO" || return 1

    # 読み書き両方で開くことで、読み手が現れるまで open がブロックするのを避ける。
    exec 9<>"$FIFO" || return 1

    case "$LOGIN_PTY" in
        1) USE_PTY=1 ;;
        0) USE_PTY=0 ;;
        *) command -v script >/dev/null 2>&1 && USE_PTY=1 || USE_PTY=0 ;;
    esac

    # 子プロセスには fd 9 (パイプの書き込み側) を渡さない
    if [ "$USE_PTY" = "1" ]; then
        # 擬似端末の桁数を広げてから起動する。既定 (80 桁) のままだと、
        # 出力を折り返すコマンドの場合に OAuth URL が途中で改行され、
        # URL を欠けた状態で拾ってしまうため。
        local cmd="stty cols ${PTY_COLS} rows ${PTY_ROWS} 2>/dev/null; ${LOGIN_CMD}"
        # -q: 開始/終了メッセージを出さない  -e: 子プロセスの終了コードを返す
        # -f: 書き込みのたびにフラッシュ (URL 検出を遅らせないため)
        script -q -e -f -c "$cmd" "$TMP_OUT" < "$FIFO" > "$TTY_OUT" 2>&1 9>&- &
    else
        # 擬似端末なし。出力を tee で画面と記録ファイルへ分ける。
        (
            exec 9>&-
            set -o pipefail
            eval "$LOGIN_CMD" < "$FIFO" 2>&1 | tee "$TMP_OUT" > "$TTY_OUT"
        ) &
    fi
    LOGIN_PID=$!
    return 0
}

# ---------------------------------------------------------------
# URL ファイルの出力。
#   生成したファイルのパスをグローバル変数へ入れる。
#     URL_FILE  … 本体 (URL を 1 行だけ書いたファイル)
#     URL_FILES … 生成した全ファイル (転送・後片付け用)
#   ※ 呼び出し元でコマンド置換 ($(...)) を使うとサブシェルになり、
#     配列への追加が親シェルへ返らないため、戻り値ではなく変数で受け渡す。
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

    # 中身は URL 1 行のみ。接続元端末で開いてそのままコピー/貼り付けできるようにする。
    ( umask 077; printf '%s\n' "$url" > "$main" ) || return 1
    URL_FILES+=("$main")

    # 常に同じ名前で参照したい場合のための最新版コピー
    if [ "$URL_LATEST" = "1" ]; then
        latest="${URL_OUT_DIR}/${URL_FILE_PREFIX}-latest.txt"
        ( umask 077; printf '%s\n' "$url" > "$latest" ) 2>/dev/null \
            && URL_FILES+=("$latest")
    fi

    # Windows のインターネットショートカット。ダブルクリックで既定のブラウザが開く。
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
# 転送用コピーの作成。作成したファイルのパスを配列 SEND_FILES へ入れる。
#   接続元端末は Windows を想定しているため、既定では改行を CRLF に変換した
#   コピーを作って転送する (EC2 側に残るファイルは LF のまま)。
#   .url ファイルは元から CRLF なので変換しない。
#   -latest.txt は同じ内容の重複なので転送対象から外す。
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
# ZMODEM (sz) で接続元端末へ送信する。
#   sz は端末を占有して stdout でプロトコルをやり取りするため、
#     - 進捗メッセージ (stderr) は画面ではなくログへ逃がす
#       (同じ端末に出すと ZMODEM のデータ列を壊すおそれがあるため)
#     - 前後で端末設定を退避・復元する
#     - 失敗時は受信側が待ち続けないよう ZMODEM のキャンセルを送る
# ---------------------------------------------------------------
zmodem_send() {
    local files=("$@")
    local rc=0
    local sz_err="${TMP_DIR}/sz.err"

    if ! command -v "$ZMODEM_CMD" >/dev/null 2>&1; then
        return 127
    fi
    [ -e /dev/tty ] || return 1

    STTY_SAVED="$(stty -g < /dev/tty 2>/dev/null)" || STTY_SAVED=""

    # aws login 側の出力と混ざらないよう、少しだけ間を置いてから始める
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
# ZMODEM 転送が使えない/失敗した場合の代替手順の案内。
#   第1引数: EC2 側の URL ファイルのパス
#   第2引数: 理由 (nosz / disabled / failed / browser)
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
        echo "    (a) TeraTerm のメニューから SCP でダウンロードする"
        echo "         [ファイル] - [SSH SCP...] を開き、Receive 欄に上記パスを入力して"
        echo "         [Receive] を押す (保存先フォルダも同じダイアログで指定できます)"
        echo "    (b) TeraTerm の ZMODEM 受信を手動で開始する"
        echo "         [ファイル] - [転送] - [ZMODEM] - [受信] を選んでから、EC2 側で"
        echo "         次を実行する"
        echo "             sz ${file}"
        echo "    (c) 同梱の aws_login_file_download.ttl (TeraTerm マクロ) を使う"
        echo "         保存先フォルダをマクロ側で指定してダウンロードできます"
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

# ---------------------------------------------------------------
# トークンの入力受付と中継。
#   端末から読み取った行を fd 9 (aws login の標準入力) へ流し込む。
#   1 秒のタイムアウト付きで読むことで、ログインプロセスの終了も監視できる。
#   追加の質問が返ってきた場合も、そのまま入力すれば中継される。
# ---------------------------------------------------------------
relay_token_input() {
    local deadline=$((SECONDS + LOGIN_WAIT))
    local line

    # 擬似端末モードでは、入力した文字が
    #   (1) 手元の端末のローカルエコー
    #   (2) aws login 側の擬似端末のエコー
    # で二重に表示される。既定では (1) を止めて二重表示を避ける。
    if [ "$USE_PTY" = "1" ] && [ "$RELAY_ECHO" != "1" ] && [ -e /dev/tty ]; then
        STTY_SAVED="$(stty -g < /dev/tty 2>/dev/null)" || STTY_SAVED=""
        [ -n "$STTY_SAVED" ] && stty -echo < /dev/tty 2>/dev/null
    fi

    while login_running; do
        if [ "$SECONDS" -ge "$deadline" ]; then
            restore_tty
            warn "トークン入力の待機が ${LOGIN_WAIT} 秒を超えました。処理を中断します。"
            return 1
        fi
        if IFS= read -r -t 1 line < /dev/tty; then
            line="${line%$'\r'}"
            printf '%s\n' "$line" >&9
        fi
    done

    restore_tty
    return 0
}

# ===============================================================
# メイン処理
# ===============================================================

info "AWS 認証状態をチェックしています..."

if is_authenticated; then
    identity=$(aws sts get-caller-identity --output text --query 'Arn' 2>/dev/null)
    info "認証済みです: ${identity}"
    marker "DONE=skipped"
    exit 0
fi

info "未認証です。${LOGIN_CMD} を実行します。"

# 画面出力先。端末があれば /dev/tty を使う (バックグラウンド実行時も表示できる)。
[ -e /dev/tty ] && TTY_OUT="/dev/tty"

TMP_DIR="$(mktemp -d /tmp/aws_login_file.XXXXXX)" || {
    warn "作業用ディレクトリを作成できませんでした。"
    exit 1
}
TMP_OUT="${TMP_DIR}/login_output.log"
FIFO="${TMP_DIR}/login_stdin"
: > "$TMP_OUT"
trap cleanup EXIT

DL_DECISION="$(should_download)"
DO_DOWNLOAD="${DL_DECISION%%:*}"
DL_REASON="${DL_DECISION#*:}"
[ "$DL_REASON" = "$DL_DECISION" ] && DL_REASON=""
if [ "$DO_DOWNLOAD" = "1" ]; then
    info "OAuth URL をファイルへ出力し、ZMODEM で接続元端末へ転送します。"
elif [ "$DL_REASON" = "macro" ]; then
    info "OAuth URL をファイルへ出力します (TeraTerm マクロが SCP で取得します)。"
else
    info "OAuth URL をファイルへ出力します (自動ダウンロードは行いません)。"
fi
echo ""

if ! start_login; then
    warn "ログインコマンドを起動できませんでした。"
    exit 1
fi

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
    marker "DONE=ng"
    exit 1
fi

# --- URL ファイルの出力 ---
if ! write_url_files "$url" || [ -z "$URL_FILE" ]; then
    warn "URL ファイルを出力できませんでした (出力先: ${URL_OUT_DIR})。"
    marker "DONE=ng"
    exit 1
fi
url_file="$URL_FILE"

echo ""
info "OAuth URL をファイルへ出力しました。"
info "  出力先: ${url_file}"

# TeraTerm マクロ (aws_login_file_download.ttl) はこの行を待ち受けて
# ダウンロード対象のパスを取得する (ファイル名はマクロ側で basename する)。
marker "PATH=${url_file}"

# --- 接続元端末への転送 ---
downloaded=0
if [ "$DO_DOWNLOAD" = "1" ]; then
    if ! make_send_files || [ "${#SEND_FILES[@]}" -eq 0 ]; then
        warn "転送用ファイルを準備できませんでした。"
        print_download_guide "$url_file" "failed"
    else
        info "ZMODEM で送信します (受信は TeraTerm が自動で開始します)..."
        zmodem_send "${SEND_FILES[@]}"
        zmodem_status=$?
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
            marker "DOWNLOAD=ok"
        else
            marker "DOWNLOAD=ng"
            if [ "$zmodem_status" -eq 127 ]; then
                print_download_guide "$url_file" "nosz"
            else
                print_download_guide "$url_file" "failed"
            fi
        fi
    fi
elif [ "$DL_REASON" = "macro" ]; then
    # TeraTerm マクロ (aws_login_file_download.ttl) が SCP で取得するため、
    # 長い案内は出さずに一言だけ添える。
    info "ダウンロードは TeraTerm マクロ (SCP) 側で行います。"
else
    print_download_guide "$url_file" "${DL_REASON:-disabled}"
fi

# --- トークンの受け渡し ---
{
    echo ""
    echo "--------------------------------------------------------------------"
    if [ "$downloaded" = "1" ]; then
        echo ">>> ダウンロードしたファイルの URL をブラウザで開いて認証してください。"
    else
        echo ">>> 上記ファイルの URL をブラウザで開いて認証してください。"
    fi
    echo ">>> 認証後に表示されたトークンを、この画面に貼り付けて Enter を押すと"
    echo ">>> 認証を続行します。"
    if [ "$USE_PTY" = "1" ] && [ "$RELAY_ECHO" != "1" ]; then
        echo ">>> (二重表示を避けるため、貼り付けた内容は Enter を押すまで表示されません)"
    fi
    echo "--------------------------------------------------------------------"
    echo ""
} > "$TTY_OUT"

# TeraTerm マクロがトークン入力ダイアログを出すための目印
marker "TOKEN_WAIT"

# トークンを中継する。待機がタイムアウトした場合は、wait で永久に
# ブロックしないようログインプロセスを終了させてから結果を確認する。
if ! relay_token_input; then
    kill "$LOGIN_PID" 2>/dev/null
fi

# --- 認証結果の確認 ---
wait "$LOGIN_PID" 2>/dev/null
login_status=$?
LOGIN_PID=""

echo ""
if [ "$login_status" -eq 0 ] && is_authenticated; then
    identity=$(aws sts get-caller-identity --output text --query 'Arn' 2>/dev/null)
    info "ログインに成功しました: ${identity}"

    # URL は一度きりの認証情報を含むため、既定では認証後に削除する。
    if [ "$URL_FILE_KEEP" = "0" ] && [ "${#URL_FILES[@]}" -gt 0 ]; then
        rm -f "${URL_FILES[@]}" 2>/dev/null
        info "EC2 側の URL ファイルを削除しました (残す場合は URL_FILE_KEEP=1)。"
    else
        info "EC2 側の URL ファイルを残しました: ${url_file}"
    fi
    if [ "$downloaded" = "1" ]; then
        info "接続元端末にダウンロードしたファイルは不要になりました。削除を推奨します。"
    fi
    marker "DONE=ok"
    exit 0
else
    warn "ログインに失敗しました (exit code: ${login_status})。"
    warn "URL ファイルは残してあります: ${url_file}"
    marker "DONE=ng"
    exit 1
fi
