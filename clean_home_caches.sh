#!/usr/bin/env bash
# =============================================================================
#  clean_home_caches.sh — Ubuntu 多用户服务器 /home 缓存清理
#
#  目标：清掉 /home 下各账号的**可再生缓存**，同时**保住模型权重**。
#
#  默认行为
#    * DRY-RUN：只统计 + 打印，一个字节都不删。确认无误后加 --apply。
#    * 每一次删除都必须通过 purge_dir() 的安全闸门：
#        必须位于白名单根目录之下 / 不含 .. / 不是符号链接 / 不是高危路径
#    * conda clean 等"必须由属主执行"的命令一律 sudo -u <user> -H，
#      避免在用户目录里留下 root 属主文件（这是原脚本最大的坑）。
#
#  数据盘
#    conda 不一定在家目录：很多机器把 anaconda 放在 /data /data2 /data3（有的机器
#    没有这些挂载）。脚本自动探测（等价于 `df -h` 看挂载点），不写死。
#    检测位置: <挂载点>/<用户>/<conda目录>、<挂载点>/<conda目录>（共享安装）、
#             家目录、以及 --conda-glob 指定的模板。
#    conda 前缀按【前缀】全局去重后只 clean 一次（共享安装在多用户下不会重复跑）。
#
#  保留 / 清理 对照
#    保留  HF      : hub/models--*/{blobs,snapshots,refs}      模型本体
#                    hub/datasets--*                          默认保留（--hf-datasets 清）
#                    transformers/                            默认保留（v4.0~4.21 的旧
#                                                             默认模型缓存，老环境含权重）
#          torch   : ~/.cache/torch/hub/checkpoints           默认保留（--deep 清）
#          conda   : envs/、用户数据、~/.ssh、代码仓库        永不触碰
#    清理  HF      : *.incomplete/*.part 残片、xet 分块缓存、assets、空壳模型目录
#          python  : pip / uv / poetry / pre-commit 缓存
#          conda   : conda clean --all（只删未被引用的包，不动 envs）
#          devtool : npm _cacache / yarn / pnpm store / cargo registry / gradle caches
#          ML      : ~/.cache/triton、torch_extensions、~/.nv/ComputeCache、
#                    wandb / matplotlib / jupyter / numba 缓存
#
#  用法：sudo ./clean_home_caches.sh --help
# =============================================================================

set -u -o pipefail

# 提权需要用原始参数重新执行，而参数解析会 shift 掉 "$@"，所以先存一份
ORIG_ARGV=("$@")

if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
  echo "需要 bash >= 4.0，当前为 ${BASH_VERSION}" >&2
  exit 1
fi

# ------------------------------- 颜色 / 日志 -------------------------------
if [ -t 1 ]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_CYN=$'\033[36m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
else
  C_RED=; C_GRN=; C_YEL=; C_CYN=; C_DIM=; C_RST=
fi
log()  { printf '%s\n' "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$C_YEL" "$C_RST" "$*" >&2; }
err()  { printf '%s[ERR ]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; }
ok()   { printf '%s[ OK ]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
hdr()  { printf '\n%s== %s ==%s\n' "$C_CYN" "$*" "$C_RST"; }

# ------------------------------- 用法 -------------------------------
usage() {
  cat <<'EOF'
用法: sudo ./clean_home_caches.sh [选项]

  不加 --apply 一律为 DRY-RUN（只报告，不删除）

  -u, --users "u1 u2"   只处理指定用户；可重复书写。默认处理 /home/* 下所有普通账号
      --skip-user "u1 u2"
                        排除指定用户；可重复书写。用于某个用户的家目录/挂载卡住时，
                        跳过它让整轮清理能跑完（实测必要）
      --hf-home 'T'     额外的 HF 缓存路径模板，%u 替换为用户名，可重复。
                        例: --hf-home '/data/%u/my_hf'
      --probe-user-shell
                        允许跑目标用户的 login shell 去读 $HF_HOME。
                        【默认关闭】——这一步会 source 别人的 profile，实测两台服务器
                        都因此在某用户处卡死。默认改用路径约定（家目录 + 数据盘）定位。
      --data-mounts "p1 p2"
                        显式指定数据盘挂载点（默认自动探测，见 --data-mount-prefix）
      --data-mount-prefix P
                        自动探测的挂载点前缀，默认 /data（即 /data /data2 /data3 … 都会被认）
      --conda-glob 'G'  额外的 conda 安装路径模板，%u 替换为用户名，可重复。
                        例: --conda-glob '/data/%u/soft/*conda*'
      --scan-data[=N]   在数据盘上全盘扫描 */bin/conda（深度 N，默认 4）。
                        路径不规律时才需要；大磁盘上较慢
      --deep            额外清理：HF 旧版 datasets 缓存、旧 transformers 缓存、
                        torch hub 预训练权重（都要重新下载，默认保留）
      --hf-datasets     额外清理 hub/datasets--*（已下载的数据集本体，通常最占地方）
      --force-rm-pkgs   兜底开关：仅当 conda clean 失败时，改为 rm -rf <前缀>/pkgs。
                        注意它【不是】conda clean —— 手段更粗暴，不区分包有没有被引用。
                        删前会检查 env 里有没有指向 pkgs 的符号链接（conda 跨文件系统时
                        会退化成软链接），有就拒绝。硬链接/副本两种模式下 env 不受影响。
      --trash           额外清空用户回收站 ~/.local/share/Trash
      --system          额外执行 apt-get clean 与 journald vacuum（只看不动 docker）
      --no-hf-prune     不调用 HuggingFace 官方 `hf cache prune`
      --allow-hf-outside-home
                        允许清理家目录之外的 HF_HOME（默认拒绝，防误删他人缓存）
  -y, --apply           真正执行删除
  -n, --dry-run         预演（默认行为，显式写出更安全）
      --nuke-hf         危险：连 HuggingFace 模型本体 (models--*) 一起删除
  -h, --help            显示本帮助

默认清理 conda 安装包（Anaconda*/Miniconda*/Miniforge*/Mambaforge*.sh），
但只删【内容确认为自解压归档】的文件，同名但不是安装包的会被跳过并列出。

典型流程:
  sudo ./clean_home_caches.sh                       # 1. 先看能清多少
  sudo ./clean_home_caches.sh -u alice              # 2. 单用户复查
  sudo ./clean_home_caches.sh --apply               # 3. 确认后执行
EOF
  exit 0
}

# ------------------------------- 参数解析 -------------------------------
APPLY=0; DEEP=0; TRASH=0; SYSTEM=0; NUKE_HF=0; NO_HF_PRUNE=0; HF_OUTSIDE_OK=0; HF_DATASETS=0
FORCE_RM_PKGS=0
PROBE_USER_SHELL=0
SCAN_DATA_DEPTH=0
DATA_MOUNT_PREFIX="/data"
declare -a TARGET_USERS=()
declare -a DATA_MOUNTS_ARG=()
declare -a CONDA_GLOBS=()
declare -a HF_HOME_PATTERNS=()
declare -a SKIP_USERS=()

while [ $# -gt 0 ]; do
  case "$1" in
    -u|--users)
      [ $# -ge 2 ] || { err "选项 $1 缺少参数"; exit 2; }
      # 故意不加引号：允许 --users "alice bob" 拆成两个用户
      # shellcheck disable=SC2206
      TARGET_USERS+=( $2 ); shift 2 ;;
    --data-mounts)
      [ $# -ge 2 ] || { err "选项 $1 缺少参数"; exit 2; }
      # shellcheck disable=SC2206
      DATA_MOUNTS_ARG+=( $2 ); shift 2 ;;
    --data-mount-prefix)
      [ $# -ge 2 ] || { err "选项 $1 缺少参数"; exit 2; }
      DATA_MOUNT_PREFIX="${2%/}"; shift 2 ;;
    --conda-glob)
      [ $# -ge 2 ] || { err "选项 $1 缺少参数"; exit 2; }
      CONDA_GLOBS+=( "$2" ); shift 2 ;;
    --scan-data)
      SCAN_DATA_DEPTH=4; shift
      # 数字可选：--scan-data 2 / --scan-data（默认 4）
      # 非数字就【不吞】这个参数，免得把后面的用户名/路径吃掉了
      if [ $# -gt 0 ]; then
        case "$1" in
          ''|*[!0-9]*) : ;;
          *) SCAN_DATA_DEPTH="$1"; shift ;;
        esac
      fi ;;
    --scan-data=*)
      SCAN_DATA_DEPTH="${1#*=}"; shift
      case "$SCAN_DATA_DEPTH" in
        ''|*[!0-9]*) err "--scan-data 需要跟一个数字，例如 --scan-data=4"; exit 2 ;;
      esac ;;
    --deep)        DEEP=1; shift ;;
    --trash)       TRASH=1; shift ;;
    --system)      SYSTEM=1; shift ;;
    --no-hf-prune) NO_HF_PRUNE=1; shift ;;
    --hf-datasets) HF_DATASETS=1; shift ;;
    --force-rm-pkgs) FORCE_RM_PKGS=1; shift ;;
    --probe-user-shell) PROBE_USER_SHELL=1; shift ;;
    --hf-home)
      [ $# -ge 2 ] || { err "选项 $1 缺少参数"; exit 2; }
      HF_HOME_PATTERNS+=( "$2" ); shift 2 ;;
    --skip-user)
      [ $# -ge 2 ] || { err "选项 $1 缺少参数"; exit 2; }
      # shellcheck disable=SC2206
      SKIP_USERS+=( $2 ); shift 2 ;;
    --allow-hf-outside-home) HF_OUTSIDE_OK=1; shift ;;
    -y|--apply)    APPLY=1; shift ;;
    -n|--dry-run)  APPLY=0; shift ;;    # 显式预演；也是默认行为，写了更不会手滑
    --nuke-hf)     NUKE_HF=1; shift ;;
    -h|--help)     usage ;;
    *) err "未知参数: $1"; usage ;;
  esac
done

# ------------------------------- 提权 -------------------------------
# 用 ORIG_ARGV（解析前保存）重新执行，否则 shift 之后参数会丢光
if [ "$(id -u)" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    log "${C_YEL}需要 root 权限（读删其他用户家目录），正在通过 sudo 重新执行…${C_RST}"
    exec sudo -- bash "$(readlink -f -- "$0")" "${ORIG_ARGV[@]}"
  fi
  err "需要 root 权限且系统无 sudo，请以 root 身份运行。"
  exit 1
fi

# =============================================================================
#  数据盘探测（等价于 `df -h` 看挂载点，但自动化）
#  默认认 /data /data2 /data3 …；有些机器有、有些没有，所以必须探测而非写死。
# =============================================================================
declare -a DATA_MOUNTS=()
declare -a _SEEN_PATHS=()
CONDA_DIRNAMES=(miniconda3 anaconda3 miniforge3 mambaforge miniconda anaconda conda)

already_seen() {
  local x
  for x in "${_SEEN_PATHS[@]}"; do [ "$x" = "$1" ] && return 0; done
  return 1
}

# 判断挂载点是否命中前缀：/data、/data/xxx、/data2、/data10（但不认 /database）
mount_matches_prefix() {
  local t="$1" p="$DATA_MOUNT_PREFIX"
  case "$t" in
    "$p"|"$p"/*) return 0 ;;
    "$p"[0-9]|"$p"[0-9]/*) return 0 ;;
    "$p"[0-9][0-9]|"$p"[0-9][0-9]/*) return 0 ;;
  esac
  return 1
}

collect_data_mounts() {
  local t rp x
  if [ "${#DATA_MOUNTS_ARG[@]}" -gt 0 ]; then
    for t in "${DATA_MOUNTS_ARG[@]}"; do
      t="${t%/}"                      # 去掉尾部 /，否则白名单模式 "$root"/* 会变成 //*
      if [ -d "$t" ]; then
        rp=$(readlink -f -- "$t")
        already_seen "$rp" || { DATA_MOUNTS+=("$t"); _SEEN_PATHS+=("$rp"); }
      else
        warn "指定的数据盘不存在，忽略: $t"
      fi
    done
    return 0
  fi

  if command -v findmnt >/dev/null 2>&1; then
    while IFS= read -r t; do
      [ -n "$t" ] || continue
      mount_matches_prefix "$t" || continue
      [ -d "$t" ] || continue
      rp=$(readlink -f -- "$t")
      already_seen "$rp" && continue     # 折叠 bind mount 重复
      DATA_MOUNTS+=("$t"); _SEEN_PATHS+=("$rp")
    done < <(findmnt -rn -o TARGET 2>/dev/null | sort -u)
  elif [ -r /proc/mounts ]; then
    while read -r _dev t _rest; do
      [ -n "${t:-}" ] || continue
      # /proc/mounts 里空格等被转义成 \040 之类，这里只处理常见的前缀匹配
      mount_matches_prefix "$t" || continue
      [ -d "$t" ] || continue
      rp=$(readlink -f -- "$t")
      already_seen "$rp" && continue
      DATA_MOUNTS+=("$t"); _SEEN_PATHS+=("$rp")
    done < /proc/mounts
  fi
}

# ------------------------------- 全局统计 -------------------------------
declare -a USER_SUMMARY=()  # "user<TAB>size"
TOTAL_KB=0
TOTAL_ITEMS=0
USER_KB=0

human() {  # 输入 KB，输出人类可读
  awk -v k="${1:-0}" 'BEGIN{
    split("KB MB GB TB PB", u, " "); i = 1;
    while (k >= 1024 && i < 5) { k /= 1024; i++ }
    printf (i == 1 ? "%.0f%s" : "%.1f%s"), k, u[i]
  }'
}

size_kb() {  # 只算一次 du，避免大目录上重复扫描
  local k
  k=$(du -sk -- "$1" 2>/dev/null | awk 'NR==1{print $1}')
  printf '%s' "${k:-0}"
}

# =============================================================================
#  安全闸门：所有删除动作的唯一入口
# =============================================================================
purge_dir() {
  local target="$1" root="$2" why="${3:-}"

  # 1) 非空
  [ -n "$target" ] || { warn "空路径，跳过"; return 1; }
  # 2) 白名单根必须绝对路径且非 /
  case "$root" in
    ""|"/"|"."|"..") err "非法白名单根: '$root'，拒绝执行"; return 1 ;;
  esac
  [ "${root#/}" != "$root" ] || { err "白名单根不是绝对路径: $root"; return 1; }
  # 3) 目标必须严格位于白名单根之下（target == root 会被下面的模式挡掉）
  case "$target" in
    "$root"/*) ;;
    *) err "越界拒绝: $target 不在 $root 之下"; return 1 ;;
  esac
  # 4) 拒绝 .. 与符号链接
  case "$target" in *..*) err "含 .. 的路径拒绝: $target"; return 1 ;; esac
  if [ -L "$target" ]; then warn "符号链接，跳过: $target"; return 0; fi
  # 5) 不存在就没事
  [ -e "$target" ] || return 0

  local kb tag
  kb=$(size_kb "$target")
  TOTAL_KB=$((TOTAL_KB + kb))
  USER_KB=$((USER_KB + kb))
  TOTAL_ITEMS=$((TOTAL_ITEMS + 1))

  if [ "$APPLY" -eq 1 ]; then
    tag="${C_RED}DEL${C_RST}"
  else
    tag="${C_DIM}DRY${C_RST}"
  fi

  printf '   %b %10s  %s' "$tag" "$(human "$kb")" "$target"
  [ -n "$why" ] && printf '  %s(%s)%s' "$C_DIM" "$why" "$C_RST"
  printf '\n'

  if [ "$APPLY" -eq 1 ]; then
    rm -rf -- "$target" || { err "删除失败: $target"; return 1; }
  fi
  return 0
}

# 只报告、不删除（用于 conda 这类交给官方命令处理的目录）
show_size() {
  local p="$1" kb
  [ -d "$p" ] || return 0
  kb=$(size_kb "$p")
  printf '   %b %10s  %s\n' "${C_DIM}---${C_RST}" "$(human "$kb")" "$p"
}

run_or_dry() {  # run_or_dry "描述" 命令...
  local desc="$1"; shift
  if [ "$APPLY" -eq 1 ]; then
    if "$@" </dev/null >/dev/null 2>&1; then ok "$desc"; else warn "$desc 失败或部分失败"; fi
  else
    printf '   %bDRY%b %s\n' "$C_DIM" "$C_RST" "$desc"
  fi
}

user_env() {  # user_env <user> <bash snippet> —— 读该用户的 shell 变量（取最后一行）
  # 【为什么写成这么绕】这一步会 source 别人的 login profile，是极易挂住的操作：
  #   1) 不能用 out=$(...)  —— 那是管道；profile 里起的后台进程会继承 stdout，
  #      命令替换会一直等 EOF，即使 timeout 已经把子进程杀掉也返回不来。
  #   2) 必须 </dev/null —— 否则 profile 里一句 `read` 就会等终端输入。
  #   3) 用 timeout -k：先 SIGTERM，5 秒后 SIGKILL。
  # 即便如此，若目标路径挂在僵死的 NFS 上（进程处于 D 状态），任何信号都杀不掉，
  # 所以调用方必须把它当作【可选】步骤 —— 见 collect_hf_candidates。
  local u="$1" snip="$2" out="" tmp
  tmp=$(mktemp 2>/dev/null) || { printf ''; return 0; }
  timeout -k 5 10 sudo -u "$u" -H bash -lc "$snip" </dev/null >"$tmp" 2>/dev/null || true
  out=$(tail -n 1 "$tmp" 2>/dev/null)
  rm -f "$tmp"
  printf '%s' "$out"
}

# =============================================================================
#  各用户处理
# =============================================================================
clean_python_caches() {
  local home="$1"
  purge_dir "$home/.cache/pip"        "$home" "pip"
  purge_dir "$home/.cache/uv"         "$home" "uv"
  purge_dir "$home/.cache/pypoetry/artifacts" "$home" "poetry"
  purge_dir "$home/.cache/pypoetry/cache"     "$home" "poetry"
  purge_dir "$home/.cache/pre-commit" "$home" "pre-commit"
}

# 非 Python 的开发者缓存：纯下载物，删掉只是重新下
# （这一块是从 v2 学来的：v1 原来完全没覆盖 node/cargo/gradle）
clean_devtool_caches() {
  local home="$1"
  purge_dir "$home/.npm/_cacache"            "$home" "npm 内容寻址缓存"
  purge_dir "$home/.npm/_logs"               "$home" "npm 日志"
  purge_dir "$home/.cache/yarn"              "$home" "yarn 缓存"
  purge_dir "$home/.cache/pnpm"              "$home" "pnpm 缓存"
  purge_dir "$home/.local/share/pnpm/store"  "$home" "pnpm store"
  purge_dir "$home/.cargo/registry/cache"    "$home" "cargo 下载的 .crate"
  purge_dir "$home/.cargo/registry/src"      "$home" "cargo 解压的源码"
  purge_dir "$home/.gradle/caches"           "$home" "gradle 依赖缓存"
}

clean_ml_caches() {
  local home="$1"
  purge_dir "$home/.cache/triton"              "$home" "triton JIT"
  purge_dir "$home/.cache/torch_extensions"    "$home" "torch extension 编译产物"
  purge_dir "$home/.cache/torch/Extensions"    "$home" "torch extension 编译产物"
  purge_dir "$home/.nv/ComputeCache"           "$home" "CUDA JIT"
  purge_dir "$home/.nv/GPUCache"               "$home" "CUDA JIT"
  purge_dir "$home/.cache/wandb"               "$home" "wandb"
  purge_dir "$home/.cache/matplotlib"          "$home" "matplotlib 字体"
  purge_dir "$home/.cache/jupyter"             "$home" "jupyter"
  purge_dir "$home/.cache/numba"               "$home" "numba JIT"

  if [ "$DEEP" -eq 1 ]; then
    # torch hub 里是 resnet 之类预训练权重，删了要重下 —— 所以只在 --deep 时动
    purge_dir "$home/.cache/torch/hub/checkpoints" "$home" "torch hub 预训练权重(--deep)"
  else
    show_size "$home/.cache/torch/hub/checkpoints"
  fi
}

# 判断 $1 这段路径是否属于用户 $2：取最近的【已存在】祖先看属主。
# 用途：区分"用户把缓存正常放到数据盘"和"环境变量异常指向了别人的目录"。
path_owned_by() {
  local p="$1" u="$2" q
  q=$(readlink -f -- "$p" 2>/dev/null) || return 1
  [ -n "$q" ] || return 1
  while [ "$q" != "/" ] && [ ! -e "$q" ]; do q=$(dirname -- "$q"); done
  [ "$(stat -c '%U' -- "$q" 2>/dev/null)" = "$u" ]
}

# =============================================================================
#  HF 缓存根解析
#
#  【设计变更 · 重要】以前这里会跑目标用户的 login shell 去读 $HF_HOME：
#      out=$(timeout 10 sudo -u "$u" -H bash -lc 'echo $HF_HOME')
#  这是全脚本唯一会执行【别人 profile】的地方，也正是实测中两台服务器都挂住的
#  位置（4090gpu-01 与另一台都在用户 feihong 处卡在 "-- HuggingFace" 之后）。
#
#  现在改为：默认【完全按路径约定】找（家目录 + 数据盘），不碰任何人的 shell。
#  只有显式加 --probe-user-shell（或旧的 --allow-hf-outside-home）才去读环境变量。
# =============================================================================
HF_CANDS=()   # 元素格式 "路径<TAB>白名单根"

_hf_cand_add() {   # <路径> <白名单根>；成功加入返回 0
  local p="$1" root="$2" x
  [ -n "$p" ] || return 1
  [ -d "$p" ] || return 1
  { [ -d "$p/hub" ] || [ -d "$p/xet" ] || [ -d "$p/assets" ] || [ -d "$p/datasets" ]; } || return 1
  for x in "${HF_CANDS[@]}"; do
    [ "${x%%$'\t'*}" = "$p" ] && return 1
  done
  HF_CANDS+=("$(printf '%s\t%s' "$p" "$root")")
  return 0
}

collect_hf_candidates() {
  local u="$1" home="$2" m g gg p hf
  HF_CANDS=()
  # 1) --hf-home 显式模板（%u 会被替换成用户名），白名单根取它自身
  for g in "${HF_HOME_PATTERNS[@]}"; do
    gg="${g//%u/$u}"
    # 故意不加引号：这里就是要做 glob 展开
    # shellcheck disable=SC2086
    for p in $gg; do _hf_cand_add "${p%/}" "${p%/}"; done
  done
  # 2) 家目录约定
  _hf_cand_add "$home/.cache/huggingface" "$home"
  _hf_cand_add "$home/huggingface"        "$home"
  # 3) 数据盘约定：<挂载点>/<用户>/...（先用属主校验，避免清到别人的）
  for m in "${DATA_MOUNTS[@]}"; do
    [ -d "$m/$u" ] || continue
    path_owned_by "$m/$u/.cache/huggingface" "$u" || continue
    _hf_cand_add "$m/$u/.cache/huggingface" "$m/$u"
    _hf_cand_add "$m/$u/huggingface"        "$m/$u"
  done
  # 4) 可选的 shell 探测（默认关；会执行别人的 profile，有挂住风险）
  if [ "$PROBE_USER_SHELL" -eq 1 ] || [ "$HF_OUTSIDE_OK" -eq 1 ]; then
    hf=$(user_env "$u" 'printf "%s" "${HF_HOME:-}"')
    if [ -n "$hf" ]; then
      if _hf_cand_add "${hf%/}" "${hf%/}"; then
        log "   · shell 探测读到 HF_HOME=${hf}（额外纳入）"
      else
        warn "   · shell 探测读到 HF_HOME=${hf}，但它不像 HF 缓存或已收录，忽略"
      fi
    fi
  fi
}

scan_one_hf() {   # <用户> <家目录> <HF根> <白名单根>
  local u="$1" home="$2" hf="$3" guard="$4"
  log "   · HF 根: $hf  ($(human "$(size_kb "$hf")"))"

  # 1) 未完成的下载残片 —— 纯垃圾
  if [ -d "$hf" ]; then
    local f
    while IFS= read -r -d '' f; do
      purge_dir "$f" "$guard" "未完成下载残片"
    done < <(find "$hf" -type f \
               \( -name '*.incomplete' -o -name '*.part' -o -name '*.partial' \) \
               -print0 2>/dev/null)
  fi

  # 2) Xet 分块缓存：官方文档明确可整体删除，已下载的模型不受影响
  purge_dir "$hf/xet" "$guard" "xet 分块缓存(可重下)"
  # 3) assets / 旧版下载目录
  purge_dir "$hf/assets"   "$guard" "assets"
  purge_dir "$hf/download" "$guard" "旧版未完成下载目录"

  # 4) 空壳仓库目录：blobs 为空（下载中断的残骸），snapshots 全是死链接
  if [ -d "$hf/hub" ]; then
    local d
    while IFS= read -r -d '' d; do
      if [ -d "$d/blobs" ] && [ -z "$(ls -A -- "$d/blobs" 2>/dev/null)" ]; then
        purge_dir "$d" "$guard" "空壳仓库目录"
      fi
    done < <(find "$hf/hub" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
  fi

  # 5) 旧版 transformers 缓存目录 —— 【不要默认删】
  #    事实：transformers v4.0.0~v4.21.x 的默认模型缓存就是 ~/.cache/huggingface/transformers，
  #    权重本体躺在那里；v4.22 才迁到 hub/，官方还留了一次性自动搬迁逻辑。
  #    所以这个目录在跑老版 transformers 的机器上 = 模型本体。默认只报告尺寸，
  #    真正清理放到 --deep。
  if [ -d "$hf/transformers" ]; then
    if [ "$DEEP" -eq 1 ]; then
      purge_dir "$hf/transformers" "$guard" "旧版 transformers 缓存(--deep，老版本可能含权重)"
    else
      show_size "$hf/transformers"
      warn "   · 上面这个 transformers/ 是 v4.0~v4.21 的旧默认模型缓存，老环境里含权重；" \
           "默认保留，确认无用再加 --deep"
    fi
  fi

  # 6) --deep：HF 旧版 datasets 缓存（arrow 格式，可重新生成）
  if [ "$DEEP" -eq 1 ]; then
    purge_dir "$hf/datasets" "$guard" "legacy datasets 缓存(--deep)"
  else
    show_size "$hf/datasets"
  fi

  # 7) --hf-datasets：hub/datasets--* 是【已下载的数据集本体】。
  #    这通常是整台服务器上仅次于模型的第一大占用，但重下 500GB 数据集很痛，
  #    所以默认绝不动，必须显式开 --hf-datasets。
  if [ "$HF_DATASETS" -eq 1 ]; then
    local ds
    for ds in "$hf/hub"/datasets--*; do
      [ -d "$ds" ] && purge_dir "$ds" "$guard" "!! 已下载数据集本体(--hf-datasets)"
    done
  elif [ -d "$hf/hub" ]; then
    local ds_total=0 ds_kb
    for ds in "$hf/hub"/datasets--*; do
      [ -d "$ds" ] || continue
      ds_kb=$(size_kb "$ds"); ds_total=$((ds_total + ds_kb))
    done
    if [ "$ds_total" -gt 0 ]; then
      printf '   %b---%b %10s  %s/hub/datasets--*  (数据集本体已保留；要清需加 --hf-datasets)\n' \
             "$C_DIM" "$C_RST" "$(human "$ds_total")" "$hf"
    fi
  fi

  # 8) --nuke-hf：真删模型，必须配 --apply 且需二次确认
  if [ "$NUKE_HF" -eq 1 ]; then
    if [ "$APPLY" -eq 1 ]; then
      warn "   · --nuke-hf 已启用：即将删除 $hf/hub 下所有模型本体"
      printf '     确认请输入 exactly: DELETE-MODELS > '
      local ans=""; read -r ans || ans=""
      if [ "$ans" = "DELETE-MODELS" ]; then
        local p
        for p in "$hf/hub"/models--*; do
          [ -d "$p" ] && purge_dir "$p" "$guard" "!! 模型本体"
        done
      else
        warn "     未确认，跳过模型删除"
      fi
    else
      printf '   %bDRY%b 将删除 %s/hub 下所有 models--*（需 --apply + 二次确认）\n' \
             "$C_DIM" "$C_RST" "$hf"
    fi
  fi

  # 9) 官方 prune：删掉没有被 ref 引用的 revision，是"保模型、腾空间"的正解
  if [ "$NO_HF_PRUNE" -eq 0 ]; then
    hf_official_prune "$u" "$home"
  fi
}

# 收集该用户的全部 HF 缓存位置并逐个处理（家目录 + 数据盘可能同时有）
clean_hf() {
  local u="$1" home="$2" entry hf guard
  collect_hf_candidates "$u" "$home"
  if [ "${#HF_CANDS[@]}" -eq 0 ]; then
    log "   · 无 HF 缓存（家目录约定与数据盘约定都没命中）"
    if [ "$PROBE_USER_SHELL" -ne 1 ] && [ "$HF_OUTSIDE_OK" -ne 1 ]; then
      log "     若该用户用非常规路径，加 --hf-home '/data/%u/my_hf' 或 --probe-user-shell"
    fi
    return 0
  fi
  [ "${#HF_CANDS[@]}" -gt 1 ] && log "   · 找到 ${#HF_CANDS[@]} 处 HF 缓存，逐个处理"
  for entry in "${HF_CANDS[@]}"; do
    hf="${entry%%$'\t'*}"
    guard="${entry#*$'\t'}"
    scan_one_hf "$u" "$home" "$hf" "$guard"
  done
  return 0
}

# 找该用户的 hf CLI：按路径查，不跑任何 shell。
# 以前这里用 `bash -lc 'command -v hf'`，代价是 source 别人的 profile ——
# 既可能挂住，也没必要，我们只是想找一个可执行文件而已。
find_hf_bin() {   # <home>；找到则输出路径
  local home="$1" p c
  for p in "$home/.local/bin/hf" "$home/bin/hf"; do
    [ -x "$p" ] && { printf '%s' "$p"; return 0; }
  done
  for c in "${CONDA_PREFIXES[@]}"; do
    case "$c" in "$home"/*) ;; *) continue ;; esac
    [ -x "$c/bin/hf" ] && { printf '%s' "$c/bin/hf"; return 0; }
  done
  return 1
}

hf_official_prune() {
  local u="$1" home="$2" hfbin out rc
  hfbin=$(find_hf_bin "$home") || {
    log "   · 未发现 hf CLI，跳过 hf cache prune（该步是可选的）"
    return 0
  }
  # 关键：hf cache prune 默认是交互式的（Proceed? [y/N]），必须显式加 -y，
  # 否则 </dev/null 读到 EOF 会静默放弃、什么也不做。
  # 另外 hf 也是 Python，同样受 multiprocessing 的 CWD 问题影响，所以走 owner_cmd。
  if [ "$APPLY" -eq 1 ]; then
    # 注意：不能写成 `if cmd | sed ...` —— 管道的退出码是最后一段(sed)的，
    # 会把失败误判成成功。必须先存 $? 再打印。
    owner_cmd 1800 "$u" "$hfbin" cache prune --yes; rc=$?; out="$OWNER_OUT"
    printf '%s\n' "$out" | sed 's/^/     /'
    if [ "$rc" -eq 0 ]; then
      ok "   · hf cache prune --yes（保留模型，仅删 detached revision + 残片）"
    else
      warn "   · hf cache prune 失败或版本不支持，跳过（不影响其它清理）"
    fi
  else
    printf '   %b--%b hf cache prune --dry-run（预览，不删）\n' "$C_DIM" "$C_RST"
    owner_cmd 300 "$u" "$hfbin" cache prune --dry-run || true
    printf '%s\n' "$OWNER_OUT" | head -n 40 | sed 's/^/     /'
  fi
}

# =============================================================================
#  conda 安装包（Anaconda/Miniconda/... .sh）清理
#  只删【内容确认为自解压 shell 归档】的文件。现实中很常见的情况是
#  /home/alice/anaconda_setup.sh 这种用户自己的脚本也叫这名 —— 只按名字删会误伤。
# =============================================================================
is_conda_installer() {
  # 判据来自【实测抓取的真实文件头】，不是猜的。
  # 真实 Miniconda3-latest / Anaconda3-2024.10 / Miniforge3 的头部长这样：
  #     # Created by constructor 3.17.1
  #     # NAME:  Miniconda3
  #     # MD5:   ddb2c339b94d5611caee2e80194d1096      <-- 冒号 + 空格，不是等号
  #     INSTALLER_NAME='Miniconda3'
  # 坑：早先写成 'MD5='（等号）→ 一个真安装包都匹配不上，
  #     实测在服务器上把 6 个真包（154MB~1GB）全误判为"不是安装包"跳过了。
  head -c 8192 -- "$1" 2>/dev/null | grep -qE \
    'Created by constructor|INSTALLER_NAME=|MD5:[[:space:]]*[0-9a-fA-F]{32}|This is a self-extracting archive'
}

clean_installers_in_dir() {   # $1=目录 $2=白名单根 $3=标签前缀
  local dir="$1" root="$2" tag="$3" f
  [ -d "$dir" ] || return 0
  while IFS= read -r -d '' f; do
    if is_conda_installer "$f"; then
      purge_dir "$f" "$root" "$tag"
    else
      warn "   · 名字像 conda 安装包但内容不是自解压归档，跳过: $f ($(human "$(size_kb "$f")"))"
    fi
  done < <(find "$dir" -mindepth 1 -maxdepth 1 -type f \
             \( -iname 'anaconda*.sh'  -o -iname 'miniconda*.sh' \
             -o -iname 'miniforge*.sh' -o -iname 'mambaforge*.sh' \
             -o -iname 'micromamba*.sh' \) -print0 2>/dev/null)
}

# =============================================================================
#  conda 探测：家目录 + 数据盘
#  conda 的探测结果按【安装前缀】全局去重（一个 prefix 只 conda clean 一次），
#  这一点很关键：/data/anaconda3 这种共享安装被 N 个用户共用，
#  按用户跑 N 次没意义还可能互踩。
# =============================================================================
declare -a CONDA_PREFIXES=()
declare -a ORPHAN_PKGS=()
declare -a CONDA_RP=()      # 与上面两个数组平行，存 realpath 用于去重

_seen_prefix() {
  local x
  for x in "${CONDA_RP[@]}"; do [ "$x" = "$1" ] && return 0; done
  return 1
}

add_conda_prefix() {   # 有 bin/conda 可执行 -> 进 CONDA_PREFIXES
  local p="$1" rp
  [ -d "$p" ] || return 0
  # 按 realpath 去重，不只是字符串去重：
  # 实测服务器上 /data/juhao/miniconda3 与 /home/juhao/miniconda3 的 pkgs 大小
  # 完全相同（都是 496.8MB），强烈提示前者是后者的符号链接。只按字符串去重
  # 会对同一个 conda 跑两次 conda clean。
  rp=$(readlink -f -- "$p" 2>/dev/null) || rp="$p"
  if [ -x "$p/bin/conda" ]; then
    _seen_prefix "$rp" && return 0
    CONDA_PREFIXES+=("$p"); CONDA_RP+=("$rp")
  elif [ -d "$p/pkgs" ]; then
    # 没有 conda 可执行文件但有 pkgs 残留 -> 孤儿包缓存
    _seen_prefix "$rp" && return 0
    ORPHAN_PKGS+=("$p"); CONDA_RP+=("$rp")
  fi
}

probe_conda_for_user() {   # 只做 -x 探测，不遍历目录，几乎零成本
  local u="$1" home="$2" m d g gg p
  for d in "${CONDA_DIRNAMES[@]}"; do
    add_conda_prefix "$home/$d"
  done
  for m in "${DATA_MOUNTS[@]}"; do
    for d in "${CONDA_DIRNAMES[@]}"; do
      add_conda_prefix "$m/$u/$d"      # /data/alice/anaconda3
    done
  done
  for g in "${CONDA_GLOBS[@]}"; do
    gg="${g//%u/$u}"
    # 故意不加引号：这里就是要做 glob 展开
    # shellcheck disable=SC2086
    for p in $gg; do add_conda_prefix "${p%/}"; done
  done
}

probe_conda_global() {   # 数据盘上的共享安装 + 可选全盘扫描
  local m d p
  for m in "${DATA_MOUNTS[@]}"; do
    for d in "${CONDA_DIRNAMES[@]}"; do
      add_conda_prefix "$m/$d"         # /data/anaconda3 共享安装
    done
  done
  if [ "$SCAN_DATA_DEPTH" -gt 0 ]; then
    for m in "${DATA_MOUNTS[@]}"; do
      log "   · 扫描 ${m}（深度 ${SCAN_DATA_DEPTH}，可能较慢）…"
      while IFS= read -r -d '' p; do
        add_conda_prefix "$(dirname -- "$(dirname -- "$p")")"
      done < <(find "$m" -maxdepth "$SCAN_DATA_DEPTH" -type f -path '*/bin/conda' -print0 2>/dev/null)
    done
  fi
}

# 检查某个 conda 前缀的 env 里，有没有【符号链接】指向该前缀的 pkgs。
#
# 为什么必须查：conda 装包时优先用硬链接（hardlink），硬链接失败才退化为
# 符号链接或直接拷贝。env 与 pkgs 在不同文件系统上时就可能退化为软链接
# （例如 conda 装在 /home，而环境用 `conda create -p /data/xxx/env` 建在 /data）。
#   - 硬链接：删 pkgs 只是减一次链接计数，env 里的实体文件还在 → 安全
#   - 拷贝：  env 是独立副本 → 安全
#   - 软链接：env 里是指向 pkgs 的链接 → 删 pkgs 会让 env 全部断链 → 【会坏】
# 所以这里只对前两种放行。
pkgs_symlink_in_env() {
  local p="$1" d hit
  for d in "$p/envs" "$p/lib" "$p/lib64"; do
    [ -d "$d" ] || continue
    hit=$(find "$d" -type l -lname "$p/pkgs/*" -print -quit 2>/dev/null)
    [ -z "$hit" ] && hit=$(find "$d" -type l -lname "*pkgs/*" -print -quit 2>/dev/null)
    [ -n "$hit" ] && { printf '%s' "$hit"; return 0; }
  done
  return 1
}

# 采样看 env 里的实体文件是否为硬链接（link count > 1），用于给出更确定的结论
env_uses_hardlinks() {
  local p="$1" f n
  f=$(find "$p/envs" "$p/lib" -type f -print -quit 2>/dev/null)
  [ -n "$f" ] || return 1
  n=$(stat -c '%h' -- "$f" 2>/dev/null) || return 1
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  [ "$n" -gt 1 ]
}

# --force-rm-pkgs 的兜底动作：conda clean 失败时直接删 <prefix>/pkgs
force_rm_pkgs() {
  local p="$1" link
  [ -d "$p/pkgs" ] || return 0
  if [ ! -x "$p/bin/conda" ]; then
    err "     拒绝：$p 下没有 bin/conda，不像 conda 安装前缀"
    return 1
  fi
  if link=$(pkgs_symlink_in_env "$p"); then
    err "     拒增强删：env 里存在指向 pkgs 的符号链接，删了会断链"
    err "       例: ${link}"
    err "       说明这个环境的 conda 走了软链接回退（env 与 pkgs 可能跨文件系统）"
    err "       该前缀请保持原样，或让属主自行处理"
    return 1
  fi
  if env_uses_hardlinks "$p"; then
    log "     已确认 env 与 pkgs 是硬链接关系，删 pkgs 不影响 env 里的文件"
  else
    log "     env 里未发现指向 pkgs 的链接（应为独立副本），删 pkgs 不影响 env"
  fi
  rm -rf -- "$p/pkgs" && ok "     已强制删除 $p/pkgs" || err "     删除失败: $p/pkgs"
}

# 安全的工作目录：所有人可进入，避免下面的 multiprocessing CWD 问题
CONDA_CWD="/"

# conda / hf 这类 Python 工具内部会用 multiprocessing 起子进程，而 CPython 的
# spawn 会把【父进程的 CWD】传给子进程并 os.chdir() 过去：
#     multiprocessing/spawn.py:186   dir=os.getcwd(),
#     multiprocessing/spawn.py:235   os.chdir(data['dir'])
# 于是，如果脚本运行时 CWD 是某个 mode 700 的家目录
#（典型场景：管理员在自己 ~ 下执行 `sudo bash clean_home_caches.sh`），
# 以【别人】身份运行的子进程 chdir 就会被拒：
#     PermissionError: [Errno 13] Permission denied: '/home/zhedongzheng'
# 实测在 4090gpu-01 上，这一条导致 19/22 个 conda 前缀的 conda clean 全部失败，
# 而报错里提到的目录是管理员的、不是目标用户的 —— 极易误判成"学生的 conda 坏了"。
# 对策：执行前切到 /。
owner_cmd() {   # <超时秒> <owner> <cmd...>
  # 输出收集到全局 OWNER_OUT，返回命令退出码。
  #
  # 【为什么必须写临时文件而不是直接输出】以属主身份跑的命令可能 source 到
  # 该用户的 profile（例如 `bash -lc 'command -v hf'`）。profile 里若起了后台进程
  #（监控 / ssh-agent / watchdog / 常驻服务），它会【继承本脚本的 stdout】。
  # 于是：脚本自己早已跑完并打印"全部完成"，但管理员那侧
  #     sudo bash clean_home_caches.sh --apply 2>&1 | tee clean_run2.log
  # 的 tee 一直等不到 EOF —— 现象就是"卡住不动"，而真正的原因跟脚本进度无关。
  # 把输出重定向到临时文件后，任何后台进程都只持有那个文件的 fd，影响不到我们的管道。
  #
  # 另外：timeout 必须在 subshell 内部（timeout 是外部命令，无法调用 shell 函数）。
  local t="$1" owner="$2"; shift 2
  local tmp rc
  tmp=$(mktemp 2>/dev/null) || { OWNER_OUT=""; return 1; }
  ( cd "$CONDA_CWD" 2>/dev/null || cd /; exec timeout "$t" sudo -u "$owner" -H "$@" </dev/null >"$tmp" 2>&1 )
  rc=$?
  OWNER_OUT=$(cat "$tmp" 2>/dev/null)
  rm -f "$tmp"
  return $rc
}

# =============================================================================
#  conda clean 的执行与诊断
# =============================================================================
CONDA_OUT=""       # 最近一次 conda clean 的输出
CONDA_HOW=""       # 哪一级重试成功的
CONDA_ERR_LOG=""   # 失败日志落盘路径，在 main 里初始化
CONDA_PKGS_KB=0    # 所有 conda 前缀的 pkgs 体积合计（用于汇总，避免"0KB"的误导）
OWNER_OUT=""       # owner_cmd 的输出缓冲区
# conda 的 bin/conda、bin/pip 等脚本在创建时会把 python 解释器的【绝对路径】
# 写死在第一行 shebang 里。目录一旦被 mv 过（很常见：/home/<u>/miniconda3
# 搬到 /data3/<u>/miniconda3），文件还在但解释器路径已失效，exec 时内核报
# "No such file or directory" —— 看起来像文件不存在，其实是解释器不存在。
conda_shebang_ok() {
  local p="$1" sh interp
  sh=$(head -n 1 -- "$p/bin/conda" 2>/dev/null) || return 0
  case "$sh" in '#!'*) ;; *) return 0 ;; esac
  interp=${sh#\#!}
  interp=${interp%% *}
  [ -n "$interp" ] || return 0
  [ -x "$interp" ]
}

# conda 崩溃时会把 traceback 打在【最前面】，末尾只是客套话。
# 之前用 tail -12 只显示了客套话，等于什么都没诊断出来。
dump_conda_error() {   # $1=前缀 $2=完整输出
  local p="$1" body="$2" n
  n=$(printf '%s\n' "$body" | wc -l)
  # 跳过开头的空行，找到第一行有内容的
  printf '%s\n' "$body" | awk 'NF{p=1} p' | head -n 18 | sed 's/^/        | /'
  [ "$n" -gt 20 ] && log "        | …（还有 $((n - 20)) 行，完整日志见 ${CONDA_ERR_LOG}）"
  if [ -n "$CONDA_ERR_LOG" ]; then
    {
      printf '\n===== %s  (属主 %s) =====\n' "$p" "$(stat -c '%U' -- "$p" 2>/dev/null)"
      printf '%s\n' "$body"
    } >> "$CONDA_ERR_LOG"
  fi
}

# 三级重试：直接执行 -> 关插件 -> 显式指定解释器（绕开失效的 shebang）
# 返回 0 表示某一级成功，并设置 CONDA_HOW / CONDA_OUT
try_conda_clean() {
  local p="$1" owner="$2" out rc
  CONDA_OUT=""; CONDA_HOW=""

  owner_cmd 1800 "$owner" "$p/bin/conda" clean --all --yes; rc=$?; out="$OWNER_OUT"
  if [ "$rc" -eq 0 ]; then CONDA_OUT="$out"; CONDA_HOW="直接执行"; return 0; fi

  # conda 自己的崩溃报告就提示了插件可能是元凶，值得照做再试一次
  owner_cmd 1800 "$owner" /usr/bin/env CONDA_NO_PLUGINS=true \
    "$p/bin/conda" clean --all --yes; rc=$?; out="$OWNER_OUT"
  if [ "$rc" -eq 0 ]; then CONDA_OUT="$out"; CONDA_HOW="关插件重试(CONDA_NO_PLUGINS=true)成功"; return 0; fi

  # shebang 失效时，显式用前缀自带的 python 去跑 conda 脚本，绕过内核的 shebang 解析
  if [ -x "$p/bin/python" ] && ! conda_shebang_ok "$p"; then
    owner_cmd 1800 "$owner" "$p/bin/python" "$p/bin/conda" clean --all --yes; rc=$?; out="$OWNER_OUT"
    if [ "$rc" -eq 0 ]; then
      CONDA_OUT="$out"; CONDA_HOW="显式解释器重试成功(shebang 已失效)"; return 0
    fi
  fi
  CONDA_OUT="$out"
  return 1
}

# 全局跑一次：按前缀去重，以【前缀属主】身份执行
clean_conda_prefixes() {
  local p owner kb_before kb_after freed
  local -a STUCK=()
  local STUCK_KB=0
  if [ "${#ORPHAN_PKGS[@]}" -gt 0 ]; then
    for p in "${ORPHAN_PKGS[@]}"; do
      purge_dir "$p/pkgs" "$p" "conda 包缓存（无 conda 可执行文件）"
    done
  fi

  if [ "${#CONDA_PREFIXES[@]}" -eq 0 ]; then
    log "   · 未发现 conda 安装（含数据盘）"
    return 0
  fi

  for p in "${CONDA_PREFIXES[@]}"; do
    owner=$(stat -c '%U' -- "$p" 2>/dev/null || echo root)
    kb_before=$(size_kb "$p/pkgs")
    CONDA_PKGS_KB=$((CONDA_PKGS_KB + kb_before))
    log "   · $p  (属主: $owner, pkgs $(human "$kb_before"))"

    if [ "$APPLY" -ne 1 ]; then
      printf '   %bDRY%b %s clean --all --yes\n' "$C_DIM" "$C_RST" "$p/bin/conda"
      continue
    fi

    if try_conda_clean "$p" "$owner"; then
      ok "     conda clean --all --yes 完成${CONDA_HOW:+（${CONDA_HOW}）}"
    else
      warn "     conda clean 仍失败，属主 ${owner}。以下是最前面的报错（traceback 在头部）:"
      dump_conda_error "$p" "$CONDA_OUT"
      if ! conda_shebang_ok "$p"; then
        err "     ↑ 诊断：$p/bin/conda 的 shebang 指向的解释器已不存在。"
        err "       该 conda 目录被搬动过（例如从 /home 移到 /data），"
        err "       conda 命令本身对这个用户已不可用，环境很可能也已失效。"
        err "       正确做法是让属主重装或修 shebang，而不是只删 pkgs。"
      fi
      if [ "$FORCE_RM_PKGS" -eq 1 ]; then
        warn "     --force-rm-pkgs 生效：改为直接删 $p/pkgs"
        force_rm_pkgs "$p"
      else
        STUCK+=("$p")
        STUCK_KB=$((STUCK_KB + kb_before))
      fi
    fi

    # 把 conda clean 实际回收的空间计入总量（以前漏算，汇总里的数字偏小）
    kb_after=$(size_kb "$p/pkgs")
    if [ "$kb_after" -lt "$kb_before" ]; then
      freed=$((kb_before - kb_after))
      TOTAL_KB=$((TOTAL_KB + freed))
      TOTAL_ITEMS=$((TOTAL_ITEMS + 1))
      printf '   %bDEL%b %10s  %s/pkgs  (回收)\n' \
             "$C_RED" "$C_RST" "$(human "$freed")" "$p"
    else
      printf '   %b---%b %10s  %s/pkgs  (未回收)\n' \
             "$C_DIM" "$C_RST" "$(human "$kb_after")" "$p"
    fi
  done

  if [ "${#STUCK[@]}" -gt 0 ]; then
    warn " 以下 ${#STUCK[@]} 个前缀的 pkgs 没能回收，累计约 $(human "$STUCK_KB")："
    printf '   %s\n' "${STUCK[@]}" | sed 's/^/     /'
    log "   加 --force-rm-pkgs 可强制删；完整报错已写入 ${CONDA_ERR_LOG}"
  fi
  return 0
}

process_user() {
  local u="$1" home="$2"
  USER_KB=0

  hdr "用户 $u  ($home)"
  if [ ! -d "$home" ]; then warn "家目录不存在，跳过"; return 0; fi

  log "-- Python / 构建缓存"
  clean_python_caches "$home"

  log "-- node / cargo / gradle 缓存"
  clean_devtool_caches "$home"

  log "-- ML 运行时缓存"
  clean_ml_caches "$home"

  log "-- HuggingFace（模型默认保留）"
  clean_hf "$u" "$home"

  log "-- conda 安装包 / conda 探测"
  clean_installers_in_dir "$home" "$home" "conda 安装包(家目录)"
  local m
  for m in "${DATA_MOUNTS[@]}"; do
    # /data/alice/ 下放着的安装包（下载后就地解压，包没删）
    if [ -d "$m/$u" ]; then
      clean_installers_in_dir "$m/$u" "$m" "conda 安装包($m/$u)"
    fi
  done
  probe_conda_for_user "$u" "$home"
  purge_dir "$home/.conda/pkgs" "$home" "conda 用户级包缓存"

  if [ "$TRASH" -eq 1 ]; then
    log "-- 回收站 (--trash)"
    purge_dir "$home/.local/share/Trash/files"   "$home" "回收站"
    purge_dir "$home/.local/share/Trash/expunged" "$home" "回收站"
  fi

  USER_SUMMARY+=("$(printf '%s\t%s' "$u" "$(human "$USER_KB")")")
  printf '   %s>> %s 小计: %s%s\n' "$C_DIM" "$u" "$(human "$USER_KB")" "$C_RST"
}

# =============================================================================
#  用户枚举
# =============================================================================
declare -A SEEN=()
declare -a SKIPPED_USERS=()
declare -a USERS=()

add_user() {
  local u="$1" h="$2" x
  [ -n "$u" ] && [ -n "$h" ] || return 0
  [ "$u" = "root" ] && return 0
  [ -n "${SEEN[$u]:-}" ] && return 0
  for x in "${SKIP_USERS[@]}"; do
    if [ "$x" = "$u" ]; then SKIPPED_USERS+=("$u"); return 0; fi
  done
  # 服务账号的家目录可能是 / 或 /nonexistent（典型：earlyoom）。
  # 放进来的后果是 "$home/.cache/pip" 变成 "//.cache/pip"，而且白名单根成了 "/"，
  # 被安全闸门拒绝后刷屏一堆 [ERR] 非法白名单根: '/'（实测在 4090gpu-01 上复现）。
  case "$h" in ""|"/"|"/nonexistent"|"/nonexistent/"*) return 0 ;; esac
  [ -d "$h" ] || return 0
  SEEN[$u]=1
  USERS+=("$u|$h")
}

if [ "${#TARGET_USERS[@]}" -gt 0 ]; then
  for u in "${TARGET_USERS[@]}"; do
    h=$(getent passwd "$u" 2>/dev/null | awk -F: 'NR==1{print $6}')
    [ -n "$h" ] || h="/home/$u"
    if [ ! -d "$h" ]; then warn "用户 $u 的家目录不存在: $h"; continue; fi
    add_user "$u" "$h"
  done
else
  # 1) passwd 里的普通账号
  #    注意：不设 uid < 60000 上限 —— 接入 AD/LDAP/SSSD 的服务器上，
  #    真实用户的 uid 常见是 100000+ 甚至十几万，卡 60000 会把真人全漏掉。
  #    只排除 nobody(65534) / nfsnobody(4294967294) 这两个哨兵值。
  while IFS=: read -r _name _pw uid _gid _gecos uhome _shell; do
    [ -n "${uid:-}" ] || continue
    case "$uid" in *[!0-9]*) continue ;; esac
    [ "$uid" -ge 1000 ] || continue
    [ "$uid" -eq 65534 ] && continue
    [ "$uid" -eq 4294967294 ] && continue
    # 自动枚举时跳过服务账号（nologin / false）。它们的家目录里不会有缓存，
    # 只会制造噪声（earlyoom 就是这一类）。真要处理就用 -u 显式指定。
    case "${_shell:-}" in
      *nologin|*false) continue ;;
    esac
    add_user "$_name" "$uhome"
  done < <(getent passwd 2>/dev/null || cat /etc/passwd)
  # 2) /home 下存在但没有 passwd 记录的目录（兜底，兼容原脚本行为）
  for d in /home/*; do
    [ -d "$d" ] || continue
    add_user "$(basename -- "$d")" "$d"
  done
fi

if [ "${#USERS[@]}" -eq 0 ]; then
  err "没有找到可处理的用户。"
  exit 1
fi

# =============================================================================
#  主流程
# =============================================================================
collect_data_mounts

printf '%s\n' "============================================================"
printf ' clean_home_caches.sh  模式: %s\n' \
  "$([ "$APPLY" -eq 1 ] && echo "${C_RED}APPLY（真删）${C_RST}" || echo "${C_GRN}DRY-RUN（只报告）${C_RST}")"
printf ' 额外开关: --deep=%s  --trash=%s  --system=%s  --nuke-hf=%s  --hf-datasets=%s  --force-rm-pkgs=%s\n' \
  "$DEEP" "$TRASH" "$SYSTEM" "$NUKE_HF" "$HF_DATASETS" "$FORCE_RM_PKGS"
printf ' 待处理用户: %s\n' "${#USERS[@]}"
if [ "${#DATA_MOUNTS[@]}" -gt 0 ]; then
  printf ' 数据盘(自动探测 %s*): %s\n' "$DATA_MOUNT_PREFIX" "${DATA_MOUNTS[*]}"
else
  printf ' 数据盘(自动探测 %s*): 未发现（要手工指定用 --data-mounts）\n' "$DATA_MOUNT_PREFIX"
fi
[ "$SCAN_DATA_DEPTH" -gt 0 ] && printf ' 数据盘全盘扫描深度: %s\n' "$SCAN_DATA_DEPTH"
[ "$PROBE_USER_SHELL" -eq 1 ] && printf ' %s注意：--probe-user-shell 已开启，会执行目标用户的 login shell（可能挂住）%s\n' "$C_YEL" "$C_RST"
if [ "${#SKIPPED_USERS[@]}" -gt 0 ]; then
  printf ' 已按 --skip-user 排除: %s\n' "${SKIPPED_USERS[*]}"
fi
printf '%s\n' "============================================================"

if [ "$APPLY" -eq 1 ] && [ "$NUKE_HF" -eq 1 ]; then
  warn "!! --nuke-hf 已开启：HuggingFace 模型本体将被删除。3 秒内 Ctrl-C 可中止…"
  sleep 3
fi

for entry in "${USERS[@]}"; do
  u="${entry%%|*}"
  h="${entry#*|}"
  process_user "$u" "$h"
done

# ---------------------------------------------------------------------------
# 循环之后：全局部分
#   (1) 数据盘共享目录 / 挂载点根目录下的 conda 安装包（只扫一次，避免 N 用户重复）
#   (2) conda 前缀按【前缀】去重后统一 clean（共享安装在多用户下只跑一次）
# ---------------------------------------------------------------------------
if [ "${#DATA_MOUNTS[@]}" -gt 0 ]; then
  hdr "数据盘全局（${DATA_MOUNTS[*]}）"
  for m in "${DATA_MOUNTS[@]}"; do
    clean_installers_in_dir "$m" "$m" "conda 安装包($m 根目录)"
  done
fi

# 注意：probe_conda_global / clean_conda_prefixes 必须放在数据盘判断【之外】。
# 家目录里的 conda 在任何机器上都可能存在；如果把它们塞进 if [ -d /data ] 里面，
# 没有数据盘的机器上家目录 conda 就永远不会被清（已实测复现过这个 bug）。
probe_conda_global

# conda clean 失败时把完整报错落盘（崩溃报告很长，终端里只显示头部）
if [ "$APPLY" -eq 1 ]; then
  if [ -w "$PWD" ]; then
    CONDA_ERR_LOG="$PWD/conda_clean_failures_$(date +%Y%m%d-%H%M%S).log"
  else
    CONDA_ERR_LOG="/tmp/conda_clean_failures_$(date +%Y%m%d-%H%M%S).log"
  fi
  : > "$CONDA_ERR_LOG" 2>/dev/null || CONDA_ERR_LOG=""
fi

hdr "conda 统一清理（按安装前缀去重）"
clean_conda_prefixes

# ------------------------------- 系统级（可选） -------------------------------
if [ "$SYSTEM" -eq 1 ]; then
  hdr "系统级清理 (--system)"
  if command -v apt-get >/dev/null 2>&1; then
    run_or_dry "apt-get clean" apt-get clean
  fi
  if command -v journalctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    run_or_dry "journalctl --vacuum-time=7d" journalctl --vacuum-time=7d
  fi
  if command -v docker >/dev/null 2>&1; then
    log "   docker 占用（不自动清理，需人工判断）:"
    docker system df 2>/dev/null | sed 's/^/     /'
  fi
fi

# ------------------------------- 汇总 -------------------------------
hdr "汇总"
if [ "$APPLY" -eq 1 ]; then
  printf ' 已删除 %d 个缓存目录，释放约 %s%s%s\n' "$TOTAL_ITEMS" "$C_GRN" "$(human "$TOTAL_KB")" "$C_RST"
else
  printf ' %sDRY-RUN%s：%d 个缓存目录，预计可释放约 %s%s%s\n' \
    "$C_YEL" "$C_RST" "$TOTAL_ITEMS" "$C_GRN" "$(human "$TOTAL_KB")" "$C_RST"
  printf ' 确认无误后加 --apply 执行；建议先 -u <单个用户> 复核一遍。\n'
fi

# conda pkgs 单独报，且【必须】报。
# 否则会出现"汇总 0KB、但下面躺着 89GB pkgs"这种自相矛盾的输出 —— 实测在
# 4090gpu-01 上就出现过：缓存清过一轮后汇总显示 0KB，而 conda pkgs 有约 89GB。
if [ "$CONDA_PKGS_KB" -gt 0 ]; then
  if [ "$APPLY" -eq 1 ]; then
    printf ' conda pkgs 合计 %s（%d 个前缀），已在上面按前缀列出回收情况\n' \
           "$(human "$CONDA_PKGS_KB")" "${#CONDA_PREFIXES[@]}"
  else
    printf ' %s注意：上面的数字不含 conda pkgs。%s\n' "$C_YEL" "$C_RST"
    printf '   conda pkgs 合计 %s%s%s（%d 个前缀），通常是最大的一块；\n' \
           "$C_GRN" "$(human "$CONDA_PKGS_KB")" "$C_RST" "${#CONDA_PREFIXES[@]}"
    printf '   conda clean 会回收其中"未被任何 env 引用"的部分，具体多少只有执行后才知道。\n'
  fi
fi
printf '\n 按用户分布：\n'
for s in "${USER_SUMMARY[@]}"; do
  IFS=$'\t' read -r su skb _ <<< "$s"
  printf '   %-20s %10s\n' "$su" "$skb"
done
printf '\n'
[ "$APPLY" -eq 1 ] && ok "全部完成。" || warn "未做任何修改（DRY-RUN）。"
exit 0
