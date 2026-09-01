#!/usr/bin/env bash
#
# aws_login_persist.sh
#   `aws login --remote` の「トークン貼り付け待ち」状態を SSH セッション
#   (TeraTerm) から切り離し、離席・切断・再接続をまたいでも継続できるように
#   するラッパースクリプト。
#
# 背景となる問題:
#   aws_login_check.sh は `aws login --remote` をフォアグラウンドで実行し、
#   OAuth URL をクリップボードへコピーしたあと、トークンの貼り付けを待つ。
#   ところが URL を別座席 (AWS コンソールに繋がる端末) まで運ぶ間に離席すると、
#   TeraTerm の SSH セッションが切れてしまい、フォアグラウンドの
#   `aws login --remote` プロセスごと SIGHUP で死ぬ。
#   その結果、せっかく取得したトークンを貼り付ける先が無くなる。
#
# このスクリプトの考え方:
#   「SSH セッションを切れないように頑張る」のではなく、
#   「SSH セッションが切れても aws login プロセスが生き残るようにする」。
#   ログイン処理を tmux (または FIFO + script(1)) の中で動かして
#   端末から独立させ、あとから attach / トークン注入できるようにする。
#
#   詳しい原理と運用手順は aws_login_session_keepalive.md を参照。
#
# 使い方 (概要):
#   ./aws_login_persist.sh start        永続セッションを作ってログインを開始
#   ./aws_login_persist.sh url          取得済み URL を再表示 / 再コピー
#   ./aws_login_persist.sh attach       待機中のセッションに再接続
#   ./aws_login_persist.sh token <TOK>  attach せずにトークンを流し込む
#   ./aws_login_persist.sh status       待機状態と経過時間を表示
#   ./aws_login_persist.sh doctor       切断要因になりうる設定を診断
#   ./aws_login_persist.sh keepalive    SSH セッションに無害な通信を流し続ける
#   ./aws_login_persist.sh stop         セッションを終了
#
# 環境変数 (省略可):
#   PERSIST_MODE       auto (既定) / tmux / fifo   永続化方式
#   PERSIST_SESSION    セッション名 (既定 aws-login)
#   PERSIST_DIR        作業ディレクトリ (既定 ~/.aws_login_persist)
#   LOGIN_CMD          実行するログインコマンド (既定 "aws login --remote")
#   CHECK_SCRIPT       併用する aws_login_check.sh のパス
#   USE_CHECK_SCRIPT   0 で aws_login_check.sh を使わず LOGIN_CMD を直接実行
#   KEEPALIVE          0 で start 時の自動キープアライブを無効化 (既定 1)
#   KEEPALIVE_INTERVAL キープアライブ送出間隔 (秒, 既定 50)
#   CODE_TTL_WARN      認可コード失効の警告しきい値 (秒, 既定 480)
#   CODE_TTL_LIMIT     認可コード失効の想定上限 (秒, 既定 600)
#   ※ CLIP_MODE / OSC52_GUIDE など aws_login_check.sh の環境変数もそのまま効く
#
set -u

SELF="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)/$(basename -- "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname -- "$SELF")"

CHECK_SCRIPT="${CHECK_SCRIPT:-${SCRIPT_DIR}/aws_login_check.sh}"
USE_CHECK_SCRIPT="${USE_CHECK_SCRIPT:-1}"

PERSIST_DIR="${PERSIST_DIR:-${HOME:-/tmp}/.aws_login_persist}"
PERSIST_SESSION="${PERSIST_SESSION:-aws-login}"
PERSIST_MODE="${PERSIST_MODE:-auto}"
LOGIN_CMD="${LOGIN_CMD:-aws login --remote}"

KEEPALIVE="${KEEPALIVE:-1}"
KEEPALIVE_INTERVAL="${KEEPALIVE_INTERVAL:-50}"

# OAuth の認可コードは短時間で失効する。RFC 6749 は「最大 10 分」を推奨値と
# しており、AWS 側の実装値は公開されていない。経過時間を表示して注意を促す。
CODE_TTL_WARN="${CODE_TTL_WARN:-480}"
CODE_TTL_LIMIT="${CODE_TTL_LIMIT:-600}"

RUNDIR="${PERSIST_DIR}/${PERSIST_SESSION}"
FIFO="${RUNDIR}/stdin.fifo"
LOG="${RUNDIR}/login.log"
CLIP_DIR="${RUNDIR}/clip"
RUNNER="${RUNDIR}/runner.sh"

KEEPALIVE_PID=""

# ---------------------------------------------------------------
# 表示ユーティリティ
# ---------------------------------------------------------------
msg()  { printf '=== %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '>>> [警告] %s\n' "$*" >&2; }
die()  { printf '>>> [エラー] %s\n' "$*" >&2; exit 1; }

hr() { printf -- '--------------------------------------------------------------------\n'; }

# 秒数を「1時間23分45秒」形式へ整形する
fmt_duration() {
    local s="$1" h m
    [ -z "$s" ] && { printf '不明'; return 0; }
    h=$(( s / 3600 )); m=$(( (s % 3600) / 60 )); s=$(( s % 60 ))
    if   [ "$h" -gt 0 ]; then printf '%d時間%d分%d秒' "$h" "$m" "$s"
    elif [ "$m" -gt 0 ]; then printf '%d分%d秒' "$m" "$s"
    else                      printf '%d秒' "$s"
    fi
}

now_epoch() { date '+%s'; }

# 日本語混在ラベルを表示幅で揃えるための概算 (全角 = 3 バイト / 幅 2 と仮定)
disp_width() {
    local s="$1" chars bytes
    chars=${#s}
    bytes=$(printf '%s' "$s" | wc -c)
    printf '%s' "$(( chars + (bytes - chars) / 2 ))"
}

pad_label() {
    local label="$1" target="${2:-30}" w pad=""
    w="$(disp_width "$label")"
    while [ "$w" -lt "$target" ]; do
        pad="${pad} "
        w=$(( w + 1 ))
    done
    printf '%s%s' "$label" "$pad"
}

# $RUNDIR 配下の 1 行ファイルを読む (無ければ空)
read_state() {
    local f="${RUNDIR}/$1"
    [ -f "$f" ] && head -n 1 "$f" 2>/dev/null || printf ''
}

write_state() {
    mkdir -p "$RUNDIR" 2>/dev/null
    printf '%s\n' "$2" > "${RUNDIR}/$1"
}

# ---------------------------------------------------------------
# OSC52 で接続元端末 (TeraTerm 等) のクリップボードへ書き込む。
#   tmux の内側から呼ばれた場合でも、start/attach 時に
#   set-clipboard on を設定してあるため tmux が外側の端末へ転送してくれる。
#   OSC52 は投げっぱなしで、成否を受信側から知ることはできない。
# ---------------------------------------------------------------
osc52_copy() {
    local text="$1" b64
    [ -e /dev/tty ] || return 1
    b64=$(printf '%s' "$text" | base64 | tr -d '\n')
    printf '\033]52;c;%s\a' "$b64" 2>/dev/null > /dev/tty
    return 0
}

# ---------------------------------------------------------------
# 永続化方式の決定
#   tmux があれば tmux、無ければ FIFO + script(1) にフォールバックする。
# ---------------------------------------------------------------
resolve_mode() {
    case "$PERSIST_MODE" in
        tmux|fifo) printf '%s' "$PERSIST_MODE"; return 0 ;;
    esac
    if command -v tmux >/dev/null 2>&1; then
        printf 'tmux'
    else
        printf 'fifo'
    fi
}

# 既に走っているセッションがあれば、その方式を優先する
session_mode() {
    local m
    m="$(read_state mode)"
    [ -n "$m" ] && { printf '%s' "$m"; return 0; }
    resolve_mode
}

tmux_target() { printf '=%s' "$PERSIST_SESSION"; }

tmux_session_exists() {
    command -v tmux >/dev/null 2>&1 || return 1
    tmux has-session -t "$(tmux_target)" 2>/dev/null
}

fifo_proc_alive() {
    local pid
    pid="$(read_state proc.pid)"
    [ -n "$pid" ] || return 1
    kill -0 "$pid" 2>/dev/null
}

# セッション (コンテナ) が存在するか
session_exists() {
    case "$(session_mode)" in
        tmux) tmux_session_exists ;;
        fifo) fifo_proc_alive ;;
        *)    return 1 ;;
    esac
}

# ログイン処理がまだ終わっていない (＝トークン待ちの可能性がある) か
login_running() {
    session_exists || return 1
    [ -n "$(read_state exit_code)" ] && return 1
    return 0
}

# ---------------------------------------------------------------
# URL の取り出し
#   1. aws_login_check.sh が保存したクリップ保存ファイル ($RUNDIR/clip)
#   2. tmux のペイン内容 / FIFO モードのログ
#   の順に探す。見つかったら $RUNDIR/url.txt と url_at に記録する。
# ---------------------------------------------------------------
capture_url() {
    local url="" newest raw

    # 1. aws_login_check.sh の保存ファイル (CLIP_SAVE_DIR を $RUNDIR/clip に向けている)
    if [ -d "$CLIP_DIR" ]; then
        newest="$(ls -1t "$CLIP_DIR"/*.txt 2>/dev/null | head -n 1)"
        if [ -n "$newest" ]; then
            url="$(grep -oE 'https://[^[:space:]]+' "$newest" 2>/dev/null | head -n 1)"
        fi
    fi

    # 2. 画面 / ログから拾う
    if [ -z "$url" ]; then
        case "$(session_mode)" in
            tmux)
                if tmux_session_exists; then
                    raw="$(tmux capture-pane -p -S - -t "$(tmux_target)" 2>/dev/null)"
                    url="$(printf '%s' "$raw" | grep -oE 'https://[^[:space:]]+' | head -n 1)"
                fi
                ;;
            fifo)
                [ -f "$LOG" ] && url="$(grep -aoE 'https://[^[:space:]]+' "$LOG" 2>/dev/null | head -n 1)"
                ;;
        esac
    fi

    # 3. 前回記録したもの
    if [ -z "$url" ] && [ -f "${RUNDIR}/url.txt" ]; then
        url="$(head -n 1 "${RUNDIR}/url.txt")"
    fi

    [ -n "$url" ] || return 1

    # 末尾に紛れ込みやすい記号を 1 文字だけ落とす
    case "$url" in
        *[\",\)\]\>]) url="${url%?}" ;;
    esac

    if [ ! -f "${RUNDIR}/url.txt" ] || [ "$(head -n 1 "${RUNDIR}/url.txt")" != "$url" ]; then
        write_state url.txt "$url"
        write_state url_at "$(now_epoch)"
    fi
    printf '%s' "$url"
}

# URL 発行からの経過秒数
url_age() {
    local at
    at="$(read_state url_at)"
    [ -n "$at" ] || return 1
    printf '%s' "$(( $(now_epoch) - at ))"
}

print_ttl_notice() {
    local age
    age="$(url_age)" || return 0
    [ -n "$age" ] || return 0
    printf '    URL 発行からの経過時間: %s\n' "$(fmt_duration "$age")"
    if [ "$age" -ge "$CODE_TTL_LIMIT" ]; then
        warn "認可コードの想定有効期限 ($(fmt_duration "$CODE_TTL_LIMIT")) を超えています。"
        info "トークンが弾かれた場合は restart で URL を取り直してください。"
    elif [ "$age" -ge "$CODE_TTL_WARN" ]; then
        warn "認可コードの失効が近い可能性があります (想定上限 $(fmt_duration "$CODE_TTL_LIMIT"))。"
    fi
}

# ---------------------------------------------------------------
# キープアライブ
#   DECSC (ESC 7 = カーソル位置と属性の保存) と DECRC (ESC 8 = その復元) は
#   対で送れば画面表示に一切影響しない no-op になる。
#   これを定期的に流すことで、NAT ゲートウェイ (既定 350 秒) や社内 FW の
#   アイドル切断を避けやすくする。
# ---------------------------------------------------------------
keepalive_loop() {
    local interval="${1:-$KEEPALIVE_INTERVAL}"
    local esc
    esc="$(printf '\033')"
    while :; do
        sleep "$interval"
        printf '%s7%s8' "$esc" "$esc" 2>/dev/null > /dev/tty || break
    done
}

start_keepalive_bg() {
    [ "$KEEPALIVE" = "0" ] && return 0
    [ -e /dev/tty ] || return 0
    keepalive_loop "$KEEPALIVE_INTERVAL" &
    KEEPALIVE_PID=$!
}

stop_keepalive_bg() {
    [ -n "$KEEPALIVE_PID" ] || return 0
    kill "$KEEPALIVE_PID" 2>/dev/null
    wait "$KEEPALIVE_PID" 2>/dev/null
    KEEPALIVE_PID=""
}

# ---------------------------------------------------------------
# 隠しサブコマンド: 永続セッションの中で実際にログイン処理を実行する。
#   利用者が直接呼ぶ必要はない。
# ---------------------------------------------------------------
cmd_runner() {
    local rc=0

    RUNDIR="${PERSIST_RUNDIR:?PERSIST_RUNDIR が未設定です}"
    CLIP_DIR="${RUNDIR}/clip"

    mkdir -p "$CLIP_DIR"
    write_state started_at "$(now_epoch)"
    rm -f "${RUNDIR}/exit_code" "${RUNDIR}/finished_at"

    # aws_login_check.sh の保存先を本セッション配下へ向けておくと、
    # あとから url サブコマンドで確実に URL を取り出せる。
    export CLIP_SAVE=1
    export CLIP_SAVE_DIR="$CLIP_DIR"

    if [ "$USE_CHECK_SCRIPT" = "1" ] && [ -x "$CHECK_SCRIPT" ]; then
        "$CHECK_SCRIPT"
        rc=$?
    else
        bash -c "$LOGIN_CMD"
        rc=$?
    fi

    write_state exit_code "$rc"
    write_state finished_at "$(now_epoch)"

    printf '\n'
    hr
    printf '  ログイン処理が終了しました (終了コード: %d)\n' "$rc"
    printf '  この画面は残してあります。\n'
    printf '    抜ける      : tmux なら Ctrl-b を押してから d、FIFO なら Ctrl-C\n'
    printf '    片付ける    : %s stop\n' "$SELF"
    hr
    return "$rc"
}

# ---------------------------------------------------------------
# tmux モード
# ---------------------------------------------------------------
tmux_prepare_options() {
    tmux start-server 2>/dev/null
    # アプリケーションが送る OSC52 を外側の端末へ転送させる
    tmux set-option -g set-clipboard on      >/dev/null 2>&1
    # aws_login_check.sh は tmux 内では DCS パススルー形式で OSC52 を送る。
    # tmux 3.3 以降はこの機能が既定で無効なので明示的に有効化する。
    tmux set-option -g allow-passthrough on  >/dev/null 2>&1
    # capture-pane で URL を遡って拾えるようスクロールバックを確保する
    tmux set-option -g history-limit 20000   >/dev/null 2>&1
    return 0
}

write_runner_script() {
    mkdir -p "$RUNDIR"
    {
        printf '#!/usr/bin/env bash\n'
        printf '# aws_login_persist.sh が自動生成したランチャー (直接編集しないこと)\n'
        printf 'export PERSIST_RUNDIR=%q\n'   "$RUNDIR"
        printf 'export CHECK_SCRIPT=%q\n'     "$CHECK_SCRIPT"
        printf 'export USE_CHECK_SCRIPT=%q\n' "$USE_CHECK_SCRIPT"
        printf 'export LOGIN_CMD=%q\n'        "$LOGIN_CMD"
        printf 'exec %q __runner\n'           "$SELF"
    } > "$RUNNER"
    chmod 700 "$RUNNER"
}

start_tmux() {
    tmux_prepare_options
    write_runner_script
    write_state mode tmux

    tmux new-session -d -s "$PERSIST_SESSION" -n awslogin "$RUNNER" \
        || die "tmux セッションの作成に失敗しました。"
    # ログイン完了後も出力を残す (attach し直して結果を確認できるようにする)。
    # remain-on-exit はウィンドウオプションなので、古い tmux 向けに
    # set-window-option へフォールバックする。
    tmux set-option -t "$(tmux_target)" remain-on-exit on >/dev/null 2>&1 \
        || tmux set-window-option -t "$(tmux_target)" remain-on-exit on >/dev/null 2>&1

    msg "tmux セッション ${PERSIST_SESSION} でログイン処理を開始しました。"
    info "SSH が切断されても、このセッションと待機中の aws login は生き残ります。"
    info "画面から抜ける (detach) : Ctrl-b を押してから d"
    info "再接続する              : ${SELF} attach"
    printf '\n'
    sleep 1
    tmux attach-session -t "$(tmux_target)"
}

# ---------------------------------------------------------------
# 端末から切り離してコマンドを起動する。
#   setsid があれば新しいセッションを作って完全に切り離す。
#   無い環境では nohup で SIGHUP を無視させる。
#   どちらも exec するだけなので、呼び出し側の $! はそのまま使える。
# ---------------------------------------------------------------
detach_run() {
    if command -v setsid >/dev/null 2>&1; then
        exec setsid "$@"
    elif command -v nohup >/dev/null 2>&1; then
        exec nohup "$@"
    else
        exec "$@"
    fi
}

# ---------------------------------------------------------------
# FIFO モード (tmux が無い環境向けのフォールバック)
#   ・名前付きパイプを aws login の標準入力にする
#   ・sleep で FIFO の書き込み側を開いたまま保持し、EOF を発生させない
#     → あとから別セッションで FIFO へ書き込むと、待機中の
#       aws login にトークンを渡せる
#   ・script(1) 経由で擬似端末 (pty) を与える。aws login が端末を
#     要求する実装であっても動くようにするため。
# ---------------------------------------------------------------
start_fifo() {
    local holder_pid proc_pid

    command -v mkfifo >/dev/null 2>&1 || die "mkfifo が見つかりません。tmux を導入してください。"

    mkdir -p "$RUNDIR" "$CLIP_DIR"
    write_runner_script
    rm -f "$FIFO"
    mkfifo -m 600 "$FIFO" || die "FIFO の作成に失敗しました: $FIFO"
    : > "$LOG"
    chmod 600 "$LOG" 2>/dev/null

    # 書き込み側を開きっぱなしにするホルダ。これが無いと、トークンを
    # 1 回書き込んだ時点で aws login 側が EOF を検知して終了してしまう。
    detach_run sh -c "exec sleep 2147483647 > \"$FIFO\"" </dev/null >/dev/null 2>&1 &
    holder_pid=$!
    write_state holder.pid "$holder_pid"

    if command -v script >/dev/null 2>&1; then
        # -q: 開始/終了メッセージ抑制  -f: 逐次フラッシュ  -c: 実行コマンド
        detach_run script -q -f -c "$RUNNER" "$LOG" < "$FIFO" > /dev/null 2>&1 &
        proc_pid=$!
        write_state driver script
    else
        # script(1) が無い環境。pty は与えられないが、標準入力から
        # トークンを読む実装であればこれでも動作する。
        detach_run "$RUNNER" < "$FIFO" > "$LOG" 2>&1 &
        proc_pid=$!
        write_state driver plain
        warn "script(1) が無いため擬似端末なしで起動しました。"
        info "aws login が端末を要求する実装の場合は tmux を導入してください。"
    fi

    write_state proc.pid "$proc_pid"
    write_state mode fifo
    write_state started_at "$(now_epoch)"

    msg "FIFO モードでログイン処理を開始しました (PID: ${proc_pid})。"
    info "SSH が切断されてもプロセスは生き残ります。"
    info "トークンの投入 : ${SELF} token <TOKEN>"
    info "出力の確認     : ${SELF} attach"
    printf '\n'

    watch_fifo_url
}

# FIFO モードで URL の出現を待ち、クリップボードへコピーする
watch_fifo_url() {
    local i url=""
    for i in $(seq 1 120); do
        url="$(capture_url 2>/dev/null)"
        [ -n "$url" ] && break
        url=""
        fifo_proc_alive || break
        sleep 0.5
    done

    if [ -z "$url" ]; then
        warn "60 秒以内に URL を検出できませんでした。"
        info "${SELF} status で出力を確認してください。"
        return 1
    fi

    print_url_block "$url"
    return 0
}

# ---------------------------------------------------------------
# URL を「コピーしやすい形」で表示し、OSC52 でもコピーを試みる
# ---------------------------------------------------------------
print_url_block() {
    local url="$1"

    osc52_copy "$url"

    printf '\n'
    printf '===== ↓↓↓ ここから COPY (下の行をダブルクリック → Ctrl+C) ↓↓↓ =====\n'
    printf '%s\n' "$url"
    printf '===== ↑↑↑ ここまで COPY ↑↑↑ =====\n\n'
    info "OSC52 でも接続元端末のクリップボードへコピーを試みました。"
    info "保存ファイル: ${RUNDIR}/url.txt"
    print_ttl_notice
    printf '\n'
}

# ===============================================================
# サブコマンド
# ===============================================================

# ---------------------------------------------------------------
# start: 永続セッションを作ってログイン処理を開始する
# ---------------------------------------------------------------
cmd_start() {
    local mode base
    base="$(basename "$SELF")"

    if session_exists; then
        if login_running; then
            msg "既に待機中のセッションがあります。attach します。"
            cmd_attach
            return $?
        fi
        msg "終了済みのセッションが残っていたため作り直します。"
        kill_session
    fi

    mkdir -p "$RUNDIR" "$CLIP_DIR"
    chmod 700 "$PERSIST_DIR" "$RUNDIR" 2>/dev/null
    rm -f "${RUNDIR}/exit_code" "${RUNDIR}/finished_at" \
          "${RUNDIR}/url.txt" "${RUNDIR}/url_at"
    rm -f "$CLIP_DIR"/*.txt 2>/dev/null
    write_state cmd "$LOGIN_CMD"

    mode="$(resolve_mode)"
    msg "永続化方式: ${mode}"
    if [ "$mode" = "fifo" ]; then
        warn "tmux が見つからないため FIFO モードで起動します。"
        info "可能なら tmux を導入してください (sudo dnf install -y tmux)。"
    fi

    start_keepalive_bg
    trap stop_keepalive_bg EXIT

    case "$mode" in
        tmux) start_tmux ;;
        fifo) start_fifo ;;
        *)    die "不明な永続化方式です: ${mode}" ;;
    esac

    printf '\n'
    hr
    printf '  離席前チェック\n'
    printf '    1. URL がコピーできているか (%s url で再表示できます)\n' "$base"
    printf '    2. この画面から抜けても待機は続きます\n'
    printf '         tmux モード : Ctrl-b を押してから d\n'
    printf '         FIFO モード : そのまま TeraTerm を閉じてよい\n'
    printf '    3. 戻ってきたら以下のどちらかでトークンを投入します\n'
    printf '         %s attach          (画面に戻って貼り付け)\n' "$base"
    printf '         %s token <TOKEN>   (画面に戻らず投入)\n' "$base"
    hr
}

# ---------------------------------------------------------------
# attach: 待機中のセッションへ戻る
# ---------------------------------------------------------------
cmd_attach() {
    local tail_pid line

    session_exists || die "待機中のセッションがありません。start から始めてください。"

    case "$(session_mode)" in
        tmux)
            tmux_prepare_options
            start_keepalive_bg
            trap stop_keepalive_bg EXIT
            msg "tmux セッション ${PERSIST_SESSION} へ接続します (detach: Ctrl-b d)。"
            tmux attach-session -t "$(tmux_target)"
            ;;
        fifo)
            msg "FIFO セッションの出力を表示します。"
            info "そのまま文字を入力して Enter を押すと aws login へ送られます。"
            info "抜けるときは Ctrl-C (ログイン処理は生き残ります)。"
            hr
            tail -n +1 -f "$LOG" &
            tail_pid=$!
            trap "kill $tail_pid 2>/dev/null; printf '\n'; exit 0" INT
            while IFS= read -r line; do
                printf '%s\n' "$line" > "$FIFO"
            done
            kill "$tail_pid" 2>/dev/null
            trap - INT
            ;;
        *)
            die "不明な永続化方式です。"
            ;;
    esac
}

# ---------------------------------------------------------------
# token: attach せずにトークンを流し込む
#   引数で渡すか、標準入力から読み込む。
#     aws_login_persist.sh token ABCDEF...
#     cat token.txt | aws_login_persist.sh token
# ---------------------------------------------------------------
cmd_token() {
    local token="${1:-}"

    if [ -z "$token" ]; then
        [ -t 0 ] && printf 'トークンを貼り付けて Enter: '
        IFS= read -r token
    fi

    # 貼り付け時に付きやすい CR と前後の空白を除去する
    token="$(printf '%s' "$token" | tr -d '\r\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

    [ -n "$token" ] || die "トークンが空です。"

    if ! session_exists; then
        warn "待機中のセッションがありません。このトークンは適用できません。"
        info "aws login のプロセスが終了していると、認可コードの交換に必要な"
        info "内部状態 (PKCE の code_verifier など) も失われるため再利用できません。"
        info "${SELF} restart で URL を取り直してください。"
        return 1
    fi

    if ! login_running; then
        warn "ログイン処理は既に終了しています (終了コード: $(read_state exit_code))。"
        info "${SELF} restart で URL を取り直してください。"
        return 1
    fi

    print_ttl_notice

    case "$(session_mode)" in
        tmux)
            tmux send-keys -t "$(tmux_target)" -l -- "$token" \
                || die "tmux へのトークン送信に失敗しました。"
            tmux send-keys -t "$(tmux_target)" Enter
            ;;
        fifo)
            printf '%s\n' "$token" > "$FIFO" \
                || die "FIFO へのトークン書き込みに失敗しました。"
            ;;
        *)
            die "不明な永続化方式です。"
            ;;
    esac

    msg "トークンを送信しました。結果を確認します..."
    sleep 3
    hr
    show_tail 20
    hr
    info "詳細は ${SELF} status もしくは ${SELF} attach で確認できます。"
}

# ---------------------------------------------------------------
# url: 取得済みの URL を再表示し、クリップボードへ再コピーする
# ---------------------------------------------------------------
cmd_url() {
    local url
    url="$(capture_url)" || die "URL がまだ取得できていません。${SELF} status で状況を確認してください。"
    print_url_block "$url"
}

# ---------------------------------------------------------------
# 画面 / ログの末尾を表示する
# ---------------------------------------------------------------
show_tail() {
    local n="${1:-15}"
    case "$(session_mode)" in
        tmux)
            if tmux_session_exists; then
                tmux capture-pane -p -t "$(tmux_target)" 2>/dev/null \
                    | grep -v '^[[:space:]]*$' | tail -n "$n"
            fi
            ;;
        fifo)
            [ -f "$LOG" ] && tail -n "$n" "$LOG" | tr -d '\r'
            ;;
    esac
}

# ---------------------------------------------------------------
# status: 状態表示
# ---------------------------------------------------------------
cmd_status() {
    local mode started elapsed url rc

    mode="$(session_mode)"
    printf 'セッション名     : %s\n' "$PERSIST_SESSION"
    printf '永続化方式       : %s\n' "$mode"
    printf '作業ディレクトリ : %s\n' "$RUNDIR"
    printf 'ログインコマンド : %s\n' "$(read_state cmd)"

    if ! session_exists; then
        printf '状態             : 停止 (セッションなし)\n'
        rc="$(read_state exit_code)"
        [ -n "$rc" ] && printf '前回の終了コード : %s\n' "$rc"
        printf '\n'
        info "start で新しいログインを開始できます。"
        return 0
    fi

    if login_running; then
        printf '状態             : 実行中 (トークン待ちの可能性あり)\n'
    else
        printf '状態             : 終了済み (終了コード: %s)\n' "$(read_state exit_code)"
    fi

    started="$(read_state started_at)"
    if [ -n "$started" ]; then
        elapsed=$(( $(now_epoch) - started ))
        printf '開始からの経過   : %s\n' "$(fmt_duration "$elapsed")"
    fi

    url="$(capture_url 2>/dev/null)" || url=""
    if [ -n "$url" ]; then
        printf 'OAuth URL        : %s\n' "$url"
        print_ttl_notice
    else
        printf 'OAuth URL        : 未検出\n'
    fi

    printf '\n'
    hr
    printf '  直近の出力\n'
    hr
    show_tail 15
    hr
}

# ---------------------------------------------------------------
# stop / restart / purge
# ---------------------------------------------------------------
kill_session() {
    local pid

    if command -v tmux >/dev/null 2>&1 && tmux_session_exists; then
        tmux kill-session -t "$(tmux_target)" 2>/dev/null
    fi

    pid="$(read_state proc.pid)"
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
    pid="$(read_state holder.pid)"
    [ -n "$pid" ] && kill "$pid" 2>/dev/null

    rm -f "$FIFO" "${RUNDIR}/proc.pid" "${RUNDIR}/holder.pid"
    return 0
}

cmd_stop() {
    if ! session_exists && [ ! -d "$RUNDIR" ]; then
        msg "停止すべきセッションはありません。"
        return 0
    fi
    kill_session
    msg "セッションを停止しました (ログは ${RUNDIR} に残しています)。"
    info "完全に削除する場合は ${SELF} purge を実行してください。"
}

cmd_purge() {
    kill_session
    rm -rf "$RUNDIR"
    msg "${RUNDIR} を削除しました。"
}

cmd_restart() {
    kill_session
    rm -f "${RUNDIR}/exit_code" "${RUNDIR}/finished_at" \
          "${RUNDIR}/url.txt" "${RUNDIR}/url_at"
    cmd_start
}

# ---------------------------------------------------------------
# keepalive: SSH セッションに無害な通信を流し続ける
#   tmux を使わずに TeraTerm の画面をそのまま維持したい場合の対症療法。
#   別の TeraTerm ウィンドウで実行しておくと、NAT ゲートウェイ (既定 350 秒)
#   や社内 FW のアイドル切断を回避しやすくなる。
#   ※ 送っているのは DECSC/DECRC (カーソル保存/復元) で、画面表示には
#      一切影響しない。
# ---------------------------------------------------------------
cmd_keepalive() {
    local interval="${1:-$KEEPALIVE_INTERVAL}"

    [ -e /dev/tty ] || die "端末がありません (/dev/tty が開けません)。"

    msg "キープアライブを開始します (間隔: ${interval} 秒)。"
    info "この画面はそのままにしておいてください。停止するには Ctrl-C。"
    info "画面表示に影響しない制御シーケンスを送っているだけです。"
    hr
    keepalive_loop "$interval"
}

# ---------------------------------------------------------------
# doctor: 切断要因になりうる設定をまとめて診断する
# ---------------------------------------------------------------
doctor_line() { printf '  %s : %s\n' "$(pad_label "$1" 30)" "$2"; }

cmd_doctor() {
    local v files tmout

    hr
    printf '  [1] 永続化に使えるコマンド\n'
    hr
    if command -v tmux >/dev/null 2>&1; then
        v="$(tmux -V 2>/dev/null)"
        doctor_line "tmux" "あり (${v})"
        case "$v" in
            *" 3."[3-9]*|*" 3.1"[0-9]*|*" "[4-9].*)
                doctor_line "  allow-passthrough" "必要 (本スクリプトが自動設定します)" ;;
            *)
                doctor_line "  allow-passthrough" "不要なバージョンです" ;;
        esac
    else
        doctor_line "tmux" "なし → FIFO モードで動作します"
        doctor_line "  導入コマンド" "sudo dnf install -y tmux"
    fi
    if command -v script >/dev/null 2>&1; then
        doctor_line "script(1)" "あり (FIFO モードで擬似端末を確保できます)"
    else
        doctor_line "script(1)" "なし (FIFO モードは擬似端末なしで動作)"
    fi
    if command -v aws >/dev/null 2>&1; then
        doctor_line "aws CLI" "$(aws --version 2>&1 | head -n 1)"
    else
        doctor_line "aws CLI" "なし"
    fi

    printf '\n'
    hr
    printf '  [2] いまの接続\n'
    hr
    if [ -n "${SSH_CONNECTION:-}" ]; then
        doctor_line "接続種別" "SSH"
        doctor_line "SSH_CONNECTION" "${SSH_CONNECTION}"
    elif [ -n "${TMUX:-}" ]; then
        doctor_line "接続種別" "tmux の内側"
    else
        doctor_line "接続種別" "SSH 環境変数なし (Session Manager の可能性)"
    fi
    doctor_line "TERM" "${TERM:-未設定}"
    doctor_line "実行ユーザ" "$(id -un 2>/dev/null)"

    printf '\n'
    hr
    printf '  [3] サーバ側のアイドル切断設定 (sshd)\n'
    hr
    if [ -r /etc/ssh/sshd_config ]; then
        v="$(grep -hiE '^[[:space:]]*ClientAlive(Interval|CountMax)' \
             /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | tr -s ' ')"
        if [ -n "$v" ]; then
            printf '%s\n' "$v" | sed 's/^/    /'
        else
            doctor_line "ClientAlive*" "未設定 (既定: Interval=0 → sshd からは切断しない)"
        fi
    else
        doctor_line "/etc/ssh/sshd_config" "読み取れません (権限不足)"
    fi
    printf '    推奨: ClientAliveInterval 60 / ClientAliveCountMax 60 (= 60 分無応答まで許容)\n'

    printf '\n'
    hr
    printf '  [4] シェルのアイドルタイムアウト (TMOUT)\n'
    hr
    tmout="${TMOUT:-}"
    if [ -n "$tmout" ]; then
        doctor_line "現在の TMOUT" "${tmout} 秒"
    else
        doctor_line "現在の TMOUT" "未設定 (このプロセス内)"
    fi
    files="$(grep -rlsE '(^|[^A-Za-z_])TMOUT=' /etc/profile /etc/profile.d /etc/bashrc 2>/dev/null | tr '\n' ' ')"
    if [ -n "$files" ]; then
        doctor_line "TMOUT を設定しているファイル" "$files"
        printf '    ※ TMOUT はシェルがプロンプトで入力待ちのときだけ働きます。\n'
        printf '      aws login が前面で動いている間は発火しませんが、その前後で\n'
        printf '      シェルが落ちると tmux 外のログイン処理も道連れになります。\n'
    else
        doctor_line "TMOUT を設定しているファイル" "見つかりません"
    fi

    printf '\n'
    hr
    printf '  [5] ネットワーク経路のアイドル切断 (代表的な既定値)\n'
    hr
    printf '    NAT ゲートウェイ           : 350 秒 (変更不可)\n'
    printf '    Network Load Balancer      : 350 秒\n'
    printf '    Session Manager アイドル   : 既定 20 分 (Session Manager の設定で変更可)\n'
    printf '    社内 FW / VPN              : 製品依存 (数分〜)\n'
    printf '    → いずれも「無通信」で切られるため、%s keepalive や\n' "$(basename "$SELF")"
    printf '      TeraTerm のハートビート (既定 60 秒) で通信を流し続けると回避できます。\n'

    printf '\n'
    hr
    printf '  [6] TeraTerm 側の設定 (接続元 Windows で実施)\n'
    hr
    cat <<'EOF'
    ■ SSH ハートビート (無通信でも定期的にパケットを送る)
      [設定(Setup)] → [SSH...] → Heartbeat(KeepAlive) interval を 60 (秒) 前後に
      TERATERM.INI では [TTSSH] セクションの HeartBeat=60
      0 にすると無効。既定でも 60 だが、0 に変更されていることがあるので確認する。

    ■ 自動切断の抑止
      [設定(Setup)] → [TCP/IP...] の「自動的にウィンドウを閉じる(Auto window close)」
      のチェックを外しておくと、切断時に画面が消えず原因を確認できる。

    ■ リモートからのクリップボードアクセス (OSC52 でのコピーに必須)
      [設定(Setup)] → [その他の設定(Additional settings)] → [制御シーケンス]
      → 「リモートからのクリップボードアクセス」を「書き込み」以上にする
      TERATERM.INI では ClipboardAccessFromRemote=write

    ■ OSC バッファ
      TERATERM.INI の MaxOSCBufferSize (既定 4096) を超える OSC52 は切り捨てられる。
      長い URL をコピーする場合は 1000000 程度へ拡大しておく。

    ■ 設定変更後は [設定の保存(Save setup...)] を忘れずに実行する。
EOF

    printf '\n'
    hr
    printf '  [7] 結論\n'
    hr
    printf '    上記 [3]〜[6] は「切れにくくする」対策であって、切れないことは保証できません。\n'
    printf '    確実なのは %s start でログイン処理を SSH から切り離すことです。\n' "$(basename "$SELF")"
    hr
}

# ---------------------------------------------------------------
# help
# ---------------------------------------------------------------
cmd_help() {
    local base
    base="$(basename "$SELF")"
    cat <<EOF
${base} - aws login --remote のトークン待ちを SSH セッションから切り離す

使い方:
  ${base} start              永続セッションを作りログイン開始 (URL を自動コピー)
  ${base} url                取得済み URL を再表示 / 再コピー
  ${base} attach             待機中のセッションへ戻る
  ${base} token [TOKEN]      attach せずにトークンを投入 (省略時は標準入力から)
  ${base} status             状態・経過時間・直近の出力を表示
  ${base} restart            セッションを作り直して URL を取り直す
  ${base} stop               セッションを停止 (ログは残す)
  ${base} purge              作業ディレクトリごと削除
  ${base} keepalive [秒]     SSH に無害な通信を流し続ける (既定 ${KEEPALIVE_INTERVAL} 秒間隔)
  ${base} doctor             切断要因になりうる設定を診断
  ${base} help               このヘルプ

典型的な流れ (座席を移動する場合):
  1. 座席A (TeraTerm) : ${base} start
                        → URL がクリップボードにコピーされる
                        → Ctrl-b d で detach、TeraTerm は閉じてよい
  2. 座席B (ブラウザ) : URL を開いて認証し、トークンを取得
  3. 座席A へ戻る     : ssh でログインし直して
                        ${base} token <TOKEN>
     ※ 座席B から Session Manager で同じインスタンスに入れる場合は、
       戻らずに座席B から手順3を実行できます (往復が不要になります)。

主な環境変数:
  PERSIST_MODE=tmux|fifo|auto   永続化方式 (既定 auto)
  PERSIST_SESSION=<名前>        セッション名 (既定 aws-login)
  LOGIN_CMD="aws login --remote" 実行するログインコマンド
  USE_CHECK_SCRIPT=0            aws_login_check.sh を使わず LOGIN_CMD を直接実行
  KEEPALIVE=0                   start/attach 中の自動キープアライブを無効化
  KEEPALIVE_INTERVAL=<秒>       キープアライブ間隔 (既定 50)
  CLIP_MODE / OSC52_GUIDE ...   aws_login_check.sh の環境変数もそのまま有効

詳細な解説: aws_login_session_keepalive.md
EOF
}

# ===============================================================
# ディスパッチ
# ===============================================================
main() {
    local sub="${1:-help}"
    [ $# -gt 0 ] && shift

    case "$sub" in
        start)              cmd_start "$@" ;;
        attach|resume)      cmd_attach "$@" ;;
        token|paste)        cmd_token "$@" ;;
        url)                cmd_url "$@" ;;
        status|st)          cmd_status "$@" ;;
        restart)            cmd_restart "$@" ;;
        stop)               cmd_stop "$@" ;;
        purge|clean)        cmd_purge "$@" ;;
        keepalive|ka)       cmd_keepalive "$@" ;;
        doctor|check)       cmd_doctor "$@" ;;
        __runner)           cmd_runner "$@" ;;
        help|-h|--help)     cmd_help ;;
        *)
            printf '不明なサブコマンドです: %s\n\n' "$sub" >&2
            cmd_help >&2
            exit 2
            ;;
    esac
}

main "$@"
