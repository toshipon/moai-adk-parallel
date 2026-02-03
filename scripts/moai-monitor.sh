#!/bin/bash

# ============================================================================
# MoAI Parallel Monitor
#
# 並列実行中の SPEC のステータスを監視・表示
#
# Usage:
#   ./scripts/moai-monitor.sh [options]
#
# Options:
#   -w, --watch            リアルタイム監視モード (5秒ごと更新)
#   -l, --logs             最新ログを表示
#   -s, --summary          完了サマリーのみ表示
#   -h, --help             ヘルプ表示
#
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOG_DIR="${PROJECT_ROOT}/.moai/logs/parallel"
SPECS_DIR="${PROJECT_ROOT}/.moai/specs"
TMUX_SESSION="moai-parallel"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
NC='\033[0m'

# ============================================================================
# Helper Functions
# ============================================================================

print_header() {
    clear
    echo ""
    echo -e "${CYAN}============================================================================${NC}"
    echo -e "${CYAN}  MoAI Parallel Monitor - $(date '+%Y-%m-%d %H:%M:%S')${NC}"
    echo -e "${CYAN}============================================================================${NC}"
    echo ""
}

get_spec_status() {
    local spec_name="$1"
    local spec_file="${SPECS_DIR}/${spec_name}/spec.md"

    if [[ -f "${spec_file}" ]]; then
        grep -E "^status:" "${spec_file}" 2>/dev/null | sed 's/status:[[:space:]]*//' | tr -d '[:space:]'
    else
        echo "unknown"
    fi
}

get_log_status() {
    local spec_name="$1"
    local latest_log=$(ls -t "${LOG_DIR}/${spec_name}-"*.log 2>/dev/null | head -1)

    if [[ -z "${latest_log}" ]]; then
        echo "no_log"
        return
    fi

    # ログの最後の部分を取得（最新状態を確認）
    local last_part=$(tail -100 "${latest_log}" 2>/dev/null)
    # 直近の部分（エラー回復判定用）
    local very_last_part=$(tail -20 "${latest_log}" 2>/dev/null)

    # 1. 実行状態の判定（複数の方法を組み合わせ）
    local window_name="${spec_name}"
    local claude_running=false

    # 方法1: ログファイルの更新時刻をチェック（30秒以内に更新されていれば実行中）
    local log_mtime=$(stat -f %m "${latest_log}" 2>/dev/null)
    local current_time=$(date +%s)
    local time_diff=$((current_time - log_mtime))
    if [[ ${time_diff} -lt 30 ]]; then
        claude_running=true
    fi

    # 方法2: tmux ペインの状態を確認（script コマンド使用時は空になる可能性あり）
    local pane_content=$(tmux capture-pane -t "${TMUX_SESSION}:${window_name}" -p 2>/dev/null | tail -10)
    if [[ -n "${pane_content}" ]]; then
        # pane_content が取得できた場合は従来の判定
        if echo "${pane_content}" | grep -qi "claude\|✻\|⎿\|Brewed\|thinking\|Whatchamacall"; then
            local last_line=$(echo "${pane_content}" | tail -1)
            if ! echo "${last_line}" | grep -qE "^[~\$%➜❯]"; then
                claude_running=true
            fi
        fi
    fi

    # 方法3: ログファイルの最後の内容から判定
    if echo "${last_part}" | grep -qiE "Whatchamacall|thinking|✻.*Worked|✻.*Brewed|⎿"; then
        # 最後に完了マーカーがなければ実行中
        if ! echo "${last_part}" | grep -qE "May the Force be with you|github\.com/.*/pull/[0-9]+"; then
            claude_running=true
        fi
    fi

    # 2. Rate limit 検出（最優先 - 実行中でも検出）
    if echo "${last_part}" | grep -q "hit your limit\|rate.limit\|resets.*pm"; then
        echo "rate_limited"
        return
    fi

    # 3. PR 作成成功を検出（最優先 - 完了状態を正確に判定）
    # "May the Force be with you" は完了マーカー
    if grep -qE "github\.com/.*/pull/[0-9]+|Created pull request|PR #[0-9]+ created|✅.*PR.*完了|May the Force be with you" "${latest_log}" 2>/dev/null; then
        # PR 作成があり、かつログに完了マーカーがある場合は success
        if grep -qE "github\.com/.*/pull/[0-9]+|Created pull request|PR #[0-9]+ created|✅.*PR" "${latest_log}" 2>/dev/null; then
            echo "success"
            return
        fi
    fi

    # 4. Claude が実行中なら、過去のエラーは無視して running を返す
    if [[ "${claude_running}" == true ]]; then
        echo "running"
        return
    fi

    # 5. シェルプロンプトに戻っているか確認
    local at_prompt=false
    if echo "${pane_content}" | grep -qE "^[~\$%➜❯]|^\s*$" && ! echo "${pane_content}" | grep -qi "claude"; then
        at_prompt=true
    fi

    if [[ "${at_prompt}" == true ]]; then
        # プロンプトに戻っている場合、PRがあれば成功
        if grep -qE "pull/[0-9]+|pr/[0-9]+|PR.*#[0-9]+" "${latest_log}" 2>/dev/null; then
            echo "success"
            return
        fi

        # 6. 致命的エラー検出（プロンプトに戻っている場合のみ）
        # ログの最後の部分でエラーを確認
        # API Error: 500, 502, 503 など
        if echo "${last_part}" | grep -qE "API Error: [45][0-9]{2}"; then
            echo "error"
            return
        fi
        # JSON形式のエラーレスポンス
        if echo "${last_part}" | grep -qE '"type"\s*:\s*"(error|api_error)"'; then
            echo "error"
            return
        fi
        # Internal server error
        if echo "${last_part}" | grep -qi "Internal server error"; then
            echo "error"
            return
        fi
        # 接続エラー
        if echo "${last_part}" | grep -qiE "connection refused|ECONNREFUSED|ETIMEDOUT|ENOTFOUND|socket hang up"; then
            echo "error"
            return
        fi
        # 認証エラー
        if echo "${last_part}" | grep -qE "Authentication failed|Unauthorized|401|403"; then
            echo "error"
            return
        fi
        # Claude固有のエラー（Overloaded など）
        if echo "${last_part}" | grep -qiE "overloaded|service unavailable|bad gateway"; then
            echo "error"
            return
        fi

        # PRもエラーもない場合は停止
        echo "stopped"
        return
    fi

    # 7. 完了マーカーがない場合は、まだ実行中とみなす
    if [[ -s "${latest_log}" ]]; then
        echo "running"
    else
        echo "pending"
    fi
}

show_status() {
    print_header

    # tmux セッション確認
    if tmux has-session -t "${TMUX_SESSION}" 2>/dev/null; then
        echo -e "${GREEN}✓ tmux セッション '${TMUX_SESSION}' が実行中${NC}"
        echo ""

        # ウィンドウ一覧
        echo -e "${BLUE}┌─────────────────────────────────────────────────────────────────┐${NC}"
        echo -e "${BLUE}│ 実行中のウィンドウ                                              │${NC}"
        echo -e "${BLUE}├─────────────────────────────────────────────────────────────────┤${NC}"

        tmux list-windows -t "${TMUX_SESSION}" -F "│ #{window_index}: #{window_name}" | while read line; do
            echo -e "${BLUE}${line}${NC}"
        done

        echo -e "${BLUE}└─────────────────────────────────────────────────────────────────┘${NC}"
    else
        echo -e "${YELLOW}⚠ tmux セッション '${TMUX_SESSION}' が見つかりません${NC}"
    fi

    echo ""

    # SPEC ステータス
    echo -e "${GREEN}┌─────────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${GREEN}│ SPEC ステータス                                                 │${NC}"
    echo -e "${GREEN}├─────────────────────────────────────────────────────────────────┤${NC}"

    local completed=0
    local running=0
    local error=0
    local pending=0
    local rate_limited=0
    local stopped=0

    # SPEC 名をユニークに抽出（重複を除去）
    local unique_specs=()
    for log_file in "${LOG_DIR}"/SPEC-*.log; do
        if [[ ! -f "${log_file}" ]]; then
            continue
        fi
        local name=$(basename "${log_file}" | sed 's/-[0-9]\{8\}-[0-9]\{6\}\.log$//')
        # 配列に含まれていなければ追加
        if [[ ${#unique_specs[@]} -eq 0 ]] || [[ ! " ${unique_specs[*]} " =~ " ${name} " ]]; then
            unique_specs+=("${name}")
        fi
    done

    # 空の場合は終了
    if [[ ${#unique_specs[@]} -eq 0 ]]; then
        echo -e "${GREEN}│${NC} ログファイルがありません"
        echo -e "${GREEN}└─────────────────────────────────────────────────────────────────┘${NC}"
        return
    fi

    # ユニークな SPEC 名ごとに処理
    for spec_name in "${unique_specs[@]}"; do
        local spec_status=$(get_spec_status "${spec_name}")
        local log_status=$(get_log_status "${spec_name}")

        local status_icon=""
        local status_color=""

        case "${log_status}" in
            success)
                status_icon="✅"
                status_color="${GREEN}"
                ((completed++))
                ;;
            rate_limited)
                status_icon="⏸️"
                status_color="${YELLOW}"
                ((rate_limited++))
                ;;
            error)
                status_icon="❌"
                status_color="${RED}"
                ((error++))
                ;;
            stopped)
                status_icon="⛔"
                status_color="${RED}"
                ((stopped++))
                ;;
            running)
                status_icon="🔄"
                status_color="${YELLOW}"
                ((running++))
                ;;
            *)
                status_icon="⏳"
                status_color="${GRAY}"
                ((pending++))
                ;;
        esac

        echo -e "${GREEN}│${NC} ${status_icon} ${spec_name}"
        echo -e "${GREEN}│${NC}    └─ SPEC: ${spec_status} / Log: ${status_color}${log_status}${NC}"
    done

    echo -e "${GREEN}└─────────────────────────────────────────────────────────────────┘${NC}"
    echo ""

    # サマリー
    echo -e "${CYAN}サマリー: ✅ ${completed} 完了 | 🔄 ${running} 実行中 | ⏸️ ${rate_limited} 制限 | ❌ ${error} エラー | ⛔ ${stopped} 停止 | ⏳ ${pending} 待機${NC}"
    echo ""
}

show_logs() {
    echo -e "${BLUE}最新ログファイル:${NC}"
    echo ""

    ls -lt "${LOG_DIR}"/SPEC-*.log 2>/dev/null | head -10 | while read line; do
        echo "  ${line}"
    done

    echo ""
    echo -e "${GRAY}ログを確認するには: tail -f ${LOG_DIR}/<SPEC-NAME>-<timestamp>.log${NC}"
}

show_summary() {
    local completed=0
    local total=0

    for spec_dir in "${SPECS_DIR}"/SPEC-*; do
        if [[ -d "${spec_dir}" ]]; then
            ((total++))
            local status=$(get_spec_status "$(basename "${spec_dir}")")
            if [[ "${status}" == "completed" ]]; then
                ((completed++))
            fi
        fi
    done

    echo ""
    echo -e "${CYAN}SPEC 完了状況: ${completed}/${total} ($(( completed * 100 / total ))%)${NC}"
    echo ""
}

cleanup_logs() {
    local mode="${1:-interactive}"
    local archive_dir="${LOG_DIR}/archive"

    echo ""
    echo -e "${CYAN}============================================================================${NC}"
    echo -e "${CYAN}  MoAI Log Cleanup${NC}"
    echo -e "${CYAN}============================================================================${NC}"
    echo ""

    # 完了済み SPEC のログを収集
    local cleanup_targets=()
    local unique_specs=()

    for log_file in "${LOG_DIR}"/SPEC-*.log; do
        if [[ ! -f "${log_file}" ]]; then
            continue
        fi
        local name=$(basename "${log_file}" | sed 's/-[0-9]\{8\}-[0-9]\{6\}\.log$//')
        if [[ ${#unique_specs[@]} -eq 0 ]] || [[ ! " ${unique_specs[*]} " =~ " ${name} " ]]; then
            unique_specs+=("${name}")
        fi
    done

    if [[ ${#unique_specs[@]} -eq 0 ]]; then
        echo -e "${GREEN}✓ クリーンナップ対象のログはありません${NC}"
        echo ""
        return 0
    fi

    for spec_name in "${unique_specs[@]}"; do
        local log_status=$(get_log_status "${spec_name}")
        if [[ "${log_status}" == "success" ]]; then
            # この SPEC の全ログファイルを収集
            while IFS= read -r log_file; do
                cleanup_targets+=("${log_file}")
            done < <(ls -t "${LOG_DIR}/${spec_name}-"*.log 2>/dev/null)
        fi
    done

    if [[ ${#cleanup_targets[@]} -eq 0 ]]; then
        echo -e "${GREEN}✓ クリーンナップ対象のログはありません${NC}"
        echo ""
        return 0
    fi

    echo -e "${YELLOW}完了済み SPEC のログファイル (${#cleanup_targets[@]} 件):${NC}"
    echo ""

    local total_size=0
    for log_file in "${cleanup_targets[@]}"; do
        local size=$(du -h "${log_file}" 2>/dev/null | cut -f1)
        local bytes=$(du -k "${log_file}" 2>/dev/null | cut -f1)
        total_size=$((total_size + bytes))
        echo "  📄 $(basename "${log_file}") (${size})"
    done

    local total_size_h=$(echo "${total_size}" | awk '{printf "%.1fM", $1/1024}')
    echo ""
    echo -e "${CYAN}合計サイズ: ${total_size_h}${NC}"
    echo ""

    if [[ "${mode}" == "force" ]]; then
        # 強制アーカイブモード
        mkdir -p "${archive_dir}"
        for log_file in "${cleanup_targets[@]}"; do
            mv "${log_file}" "${archive_dir}/"
        done
        echo -e "${GREEN}✓ ${#cleanup_targets[@]} 件のログを archive/ に移動しました${NC}"
    else
        # インタラクティブモード
        echo -e "${YELLOW}オプション:${NC}"
        echo "  1) archive/ に移動 (推奨)"
        echo "  2) 完全に削除"
        echo "  3) キャンセル"
        echo ""
        read -p "選択 [1-3]: " choice

        case "${choice}" in
            1)
                mkdir -p "${archive_dir}"
                for log_file in "${cleanup_targets[@]}"; do
                    mv "${log_file}" "${archive_dir}/"
                done
                echo ""
                echo -e "${GREEN}✓ ${#cleanup_targets[@]} 件のログを archive/ に移動しました${NC}"
                echo -e "${GRAY}場所: ${archive_dir}${NC}"
                ;;
            2)
                read -p "本当に削除しますか？ [y/N]: " confirm
                if [[ "${confirm}" =~ ^[Yy]$ ]]; then
                    for log_file in "${cleanup_targets[@]}"; do
                        rm -f "${log_file}"
                    done
                    echo ""
                    echo -e "${GREEN}✓ ${#cleanup_targets[@]} 件のログを削除しました${NC}"
                else
                    echo "キャンセルしました"
                fi
                ;;
            *)
                echo "キャンセルしました"
                ;;
        esac
    fi
    echo ""
}

watch_mode() {
    while true; do
        show_status
        echo -e "${GRAY}(5秒ごとに更新中... Ctrl+C で終了)${NC}"
        sleep 5
    done
}

show_help() {
    cat << EOF
MoAI Parallel Monitor - 並列実行ステータス監視

Usage: $0 [options]

Options:
  -w, --watch            リアルタイム監視モード (5秒ごと更新)
  -l, --logs             最新ログファイル一覧
  -s, --summary          完了サマリーのみ表示
  -c, --cleanup          完了済みログをクリーンナップ (インタラクティブ)
  --cleanup-force        完了済みログを archive/ に自動移動
  -h, --help             このヘルプを表示

Examples:
  $0                     # 現在のステータス表示
  $0 --watch             # リアルタイム監視
  $0 --logs              # ログファイル一覧
  $0 --cleanup           # 完了済みログを整理

tmux 操作:
  tmux attach -t moai-parallel       # セッションにアタッチ
  Ctrl+b n                           # 次のウィンドウ
  Ctrl+b p                           # 前のウィンドウ
  Ctrl+b d                           # デタッチ

EOF
}

# ============================================================================
# Main
# ============================================================================

main() {
    case "${1:-}" in
        -w|--watch)
            watch_mode
            ;;
        -l|--logs)
            show_logs
            ;;
        -s|--summary)
            show_summary
            ;;
        -c|--cleanup)
            cleanup_logs interactive
            ;;
        --cleanup-force)
            cleanup_logs force
            ;;
        -h|--help)
            show_help
            ;;
        *)
            show_status
            ;;
    esac
}

main "$@"
