#!/usr/bin/env bash
# 最简发布：dist 预构建 jar + java8，生成后先预览，确认再写 Apifox。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
CLI_JAR="$SCRIPT_DIR/dist/apifox-cli.jar"
BASE_CONF="${PUB_CONF:-$SCRIPT_DIR/.config/apifox/config.yml}"
LOCAL_CONF="${XDG_CONFIG_HOME:-$HOME/.config}/apifox/config.yml"
CONF="$BASE_CONF"
[[ -n "${PUB_CONF:-}" || ! -f "$LOCAL_CONF" ]] || CONF="$LOCAL_CONF"

usage() {
  cat <<'EOF'
用法: apifox-pub.sh <controller包> [apifox项目ID] [系统前缀] [选项]
      apifox-pub.sh <项目目录> <controller包> [apifox项目ID] [系统前缀] [选项]

位置参数:
  controller包      controller 根包（第一种写法：项目目录取当前路径）
  项目目录          业务项目根目录（默认当前路径），自动找其中的 fat jar，不编译
  apifox项目ID      可选，缺省取 YAML 配置中同名项目的配置
  系统前缀          可选，缺省取 YAML；仍为空则不加前缀

选项:
  --branch <name>   写指定分支（不创建）
  --main            直接写源分支（需项目开启外部 AI 编辑权限）
  --from <branch>   AI 分支的源分支，默认 main
  --title <name>    模块名/文档标题，默认项目目录名
  --build           强制先构建
  --no-build        不构建，直接用现有 fat jar
  -y, --yes         跳过确认，直接发布
  -h, --help        显示帮助

环境变量:
  JAVA8_HOME          JDK8 目录（默认探测 PATH 中的 java）
  PUB_CONF            YAML 配置路径，默认仓库内 .config/apifox/config.yml
  PUB_SOURCE_BRANCH   源分支，覆盖 YAML defaults
  PUB_OVERWRITE_MODE  冲突策略，覆盖 YAML defaults
  PUB_BUILD_CMD       构建命令，默认 mvn -DskipTests package

配置: 仓库内 .config/apifox/config.yml（示例）；本地真实值放 ~/.config/apifox/config.yml（或 XDG_CONFIG_HOME 下），优先读取。
默认：源码比编译产物新时自动构建；生成后打印预览，确认才写入 AI 分支。

示例:
  cd /path/to/business-project
  apifox-pub.sh com.example.demo.controller

退出码: 0 成功 / 1 参数或生成失败 / 2 未扫到 controller / 3 AI 写入权限受限 / 4 导入或回读失败
EOF
}

die() { echo "ERROR: $*" >&2; exit 1; }

# Java 8：JAVA8_HOME > JAVA_HOME > PATH 中的 java（须为 1.8）
JAVA8_HOME="${JAVA8_HOME:-}"
if [[ -z "$JAVA8_HOME" ]]; then
  java_bin="$(command -v java || true)"
  for c in "${JAVA_HOME:-}" "${java_bin%/bin/java}"; do
    if [[ -n "$c" && -x "$c/bin/java" ]] && "$c/bin/java" -version 2>&1 | grep -q '1\.8'; then
      JAVA8_HOME="$c"; break
    fi
  done
fi
[[ -n "$JAVA8_HOME" ]] || die "找不到 Java 8，请设置 JAVA8_HOME 指向 JDK8 目录"
JAVA="$JAVA8_HOME/bin/java"
BUILD_CMD="${PUB_BUILD_CMD:-mvn -DskipTests package}"

DIR="" ; INCLUDE="" ; PROJECT="" ; PREFIX="" ; BRANCH="" ; BRANCH_GIVEN=0 ; MAIN=0 ; YES=0 ; POS=()
FROM="" ; TITLE="" ; TITLE_SET=0 ; NO_BUILD=0 ; FORCE_BUILD=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch) BRANCH="${2:?}"; BRANCH_GIVEN=1; shift 2 ;;
    --main) MAIN=1; shift ;;
    --from) FROM="${2:?}"; shift 2 ;;
    --title) TITLE="${2:?}"; TITLE_SET=1; shift 2 ;;
    --build) FORCE_BUILD=1; shift ;;
    --no-build) NO_BUILD=1; shift ;;
    -y|--yes) YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) die "未知参数: $1（--help 查看用法）" ;;
    *)
      POS+=("$1"); shift ;;
  esac
done

# 第一个位置参数是目录 -> <目录> <包> ...；否则 <包> [项目ID] [前缀]，目录取当前路径
if [[ ${#POS[@]} -ge 2 && -d "${POS[0]}" ]]; then
  DIR="${POS[0]}"; INCLUDE="${POS[1]}"; PROJECT="${POS[2]:-}"; PREFIX="${POS[3]:-}"
else
  DIR="$PWD"; INCLUDE="${POS[0]:-}"; PROJECT="${POS[1]:-}"; PREFIX="${POS[2]:-}"
fi

[[ -n "$DIR" ]] || die "缺少项目目录（--help 查看用法）"
[[ -n "$INCLUDE" ]] || die "缺少 controller 包"
[[ -d "$DIR" ]] || die "目录不存在: $DIR"
if [[ ! -f "$CLI_JAR" ]]; then
  echo "未找到 CLI jar，自动构建: $SCRIPT_DIR (mvn -DskipTests package)" >&2
  ( cd "$SCRIPT_DIR" && JAVA_HOME="$JAVA8_HOME" mvn -DskipTests package ) || die "CLI 构建失败"
  mkdir -p "$SCRIPT_DIR/dist"
  cp "$SCRIPT_DIR/target/apifox-cli.jar" "$CLI_JAR" || die "复制 CLI jar 失败"
  echo "CLI jar 已就绪: $CLI_JAR" >&2
fi
command -v apifox >/dev/null || die "未安装 apifox CLI"
command -v python3 >/dev/null || die "需要 python3"

DIR="$(cd "$DIR" && pwd)"
NAME="$(basename "$DIR")"

# YAML 配置：<项目目录名> 对应 projects 下的条目；命令行与环境覆盖 YAML
CONF_PROJECT="" ; CONF_PREFIX="" ; CONF_TITLE="" ; CONF_BRANCH="" ; CONF_FROM="" ; CONF_OVERWRITE="" ; CONF_KNOWN=""
if [[ -f "$CONF" ]]; then
  CONF_LINE="$(python3 - "$CONF" "$NAME" <<'PY' 2>&1
import sys
try:
    import yaml
except ImportError:
    sys.exit('ERROR: 解析 YAML 需要 PyYAML（pip install pyyaml）')
d = yaml.safe_load(open(sys.argv[1], encoding='utf-8')) or {}
defs = d.get('defaults') or {}
projects = d.get('projects') or {}
proj = projects.get(sys.argv[2]) or {}
def val(key):
    v = proj.get(key, defs.get(key, ''))
    return '' if v is None else str(v)
fields = [val(k) for k in ('apifox_project', 'path_prefix', 'module', 'branch',
                           'source_branch', 'overwrite_mode')]
fields.append(';'.join(str(k) for k in projects))
print('|'.join(fields))
PY
  )" || die "配置解析失败: $CONF: ${CONF_LINE##*$'\n'}"
  IFS='|' read -r CONF_PROJECT CONF_PREFIX CONF_TITLE CONF_BRANCH CONF_FROM CONF_OVERWRITE CONF_KNOWN <<<"$CONF_LINE"
fi
FROM="${PUB_SOURCE_BRANCH:-${CONF_FROM:-main}}"
OVERWRITE_MODE="${PUB_OVERWRITE_MODE:-${CONF_OVERWRITE:-overwrite}}"
[[ -n "$PROJECT" ]] || PROJECT="$CONF_PROJECT"
[[ -n "$PREFIX" ]] || PREFIX="$CONF_PREFIX"
[[ $TITLE_SET -eq 1 ]] || TITLE="${CONF_TITLE:-$NAME}"
[[ -n "$BRANCH" ]] || BRANCH="$CONF_BRANCH"
OUT="$DIR/target/$TITLE.openapi.json"
if [[ -z "$PROJECT" ]]; then
  die "缺少 apifox 项目 ID：命令行未传，YAML 中也没有 \"$NAME\"${CONF_KNOWN:+（已配置: ${CONF_KNOWN//;/ }）}"
fi

find_fat_jars() {
  find "$DIR" -maxdepth 4 -type f \( -path '*/target/*.jar' -o -path '*/build/libs/*.jar' \) \
      ! -name '*-sources.jar' ! -name '*-javadoc.jar' -printf '%T@\t%p\n' \
    | sort -rn | cut -f2- | while IFS= read -r f; do
        unzip -l "$f" 'BOOT-INF/*' >/dev/null 2>&1 && printf '%s\n' "$f"
      done
}

# 源码 / 构建文件的最新时间（跳过产物目录）
newest_src() {
  find "$DIR" \( -name target -o -name build -o -name .git \) -prune -o \
    -type f \( -name '*.java' -o -name 'pom.xml' -o -name 'build.gradle' -o -name 'build.gradle.kts' \) \
    -printf '%T@\t%p\n' | sort -rn | sed -n '1p'
}

# 编译产物的最新时间（class 时间戳不受可重现构建归零影响）
newest_class() {
  find "$DIR" -type f -name '*.class' \( -path '*/target/classes/*' -o -path '*/build/classes/*' \) \
    -printf '%T@\t%p\n' | sort -rn | sed -n '1p'
}

stale_reason=""
if [[ $NO_BUILD -eq 0 ]]; then
  SRC="$(newest_src)"
  CLS="$(newest_class)"
  if [[ -z "$CLS" ]]; then
    stale_reason="没有编译产物"
  elif [[ -n "$SRC" ]] && awk -v a="${SRC%%$'\t'*}" -v b="${CLS%%$'\t'*}" 'BEGIN{exit !(a>b)}'; then
    stale_reason="源码比编译产物新: ${SRC#*$'\t'}"
  fi
fi

if [[ $NO_BUILD -eq 1 ]]; then
  echo "跳过构建（--no-build）" >&2
elif [[ $FORCE_BUILD -eq 1 || -n "$stale_reason" ]]; then
  [[ $FORCE_BUILD -eq 1 ]] && echo "强制构建: $BUILD_CMD" >&2 || echo "$stale_reason，自动构建: $BUILD_CMD" >&2
  ( cd "$DIR" && eval "$BUILD_CMD" ) || die "构建失败，未发布"
fi

mapfile -t JARS < <(find_fat_jars)
[[ ${#JARS[@]} -gt 0 ]] || die "未找到含 BOOT-INF/ 的 fat jar"
JAR="${JARS[0]}"
if [[ ${#JARS[@]} -gt 1 ]]; then
  printf 'WARN: 找到 %d 个 fat jar:\n' "${#JARS[@]}" >&2
  printf '  %s\n' "${JARS[@]}" >&2
  die "无法可靠选择 fat jar（时间戳可能被可重现构建归零），请只保留一个后重试"
fi
echo "fat jar: $JAR ($(date -r "$JAR" '+%F %T'))" >&2

echo "生成: $OUT" >&2
mkdir -p "$(dirname "$OUT")"
GEN=(--jar "$JAR" --include "$INCLUDE" --title "$TITLE" --out "$OUT")
[[ -n "$PREFIX" ]] && GEN+=(--path-prefix "$PREFIX")
set +e
"$JAVA" -jar "$CLI_JAR" "${GEN[@]}"
CODE=$?
set -e
[[ $CODE -eq 2 ]] && die "未扫到 @RestController（检查包名）"
[[ $CODE -ne 0 ]] && exit 1

SOURCE_BRANCH="$FROM"
APIFOX_ARGS=(--project "$PROJECT")
[[ -n "${APIFOX_ACCESS_TOKEN:-}" ]] && APIFOX_ARGS+=(--access-token "$APIFOX_ACCESS_TOKEN")

branch_state() {
  apifox branch list "${APIFOX_ARGS[@]}" --type all 2>/dev/null \
    | python3 -c 'import json,sys
name=sys.argv[1]
try:
    rows=json.load(sys.stdin).get("data") or []
except Exception:
    print("absent"); raise SystemExit
for b in rows:
    if b.get("name")==name:
        print("archived" if b.get("isArchived") else "active"); break
else:
    print("absent")' "$1"
}

BRANCH_STATE="absent"
if [[ $MAIN -eq 1 ]]; then
  [[ -n "$BRANCH" ]] || BRANCH="$SOURCE_BRANCH"
else
  [[ -n "$BRANCH" ]] || BRANCH="ai/$(date +%Y%m%d)-from-${SOURCE_BRANCH//\//-}-$NAME"
  BRANCH_STATE="$(branch_state "$BRANCH" || true)"
  [[ -n "$BRANCH_STATE" ]] || BRANCH_STATE="absent"
fi
if [[ "$BRANCH_STATE" == "archived" ]]; then
  echo "WARN: 分支 $BRANCH 已归档且服务端不允许删除，改用新的 AI 分支" >&2
  base="ai/$(date +%Y%m%d)-from-${SOURCE_BRANCH//\//-}-$NAME"
  BRANCH="$base"; n=1
  while [[ "$(branch_state "$BRANCH")" == "archived" ]]; do
    n=$((n + 1)); BRANCH="$base-$n"
    [[ $n -gt 20 ]] && die "找不到可用分支名（$base-*）"
  done
  BRANCH_STATE="$(branch_state "$BRANCH" || true)"
  echo "改用分支: $BRANCH" >&2
fi

PROJECT_NAME="$(apifox project get "$PROJECT" 2>/dev/null \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["name"])' 2>/dev/null || echo "$PROJECT")"

python3 - "$OUT" "$PROJECT_NAME" "$BRANCH" "$TITLE" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding='utf-8'))
methods = {'get','post','put','patch','delete','head','options','trace'}
ops = writes = 0
lines = []
for p, item in sorted(d.get('paths', {}).items()):
    for m, op in item.items():
        if m not in methods: continue
        ops += 1
        if m in ('post','put','patch'): writes += 1
        lines.append(f"  {m.upper():<7}{p}")
schemas = len((d.get('components') or {}).get('schemas') or {})
print(f"\n项目 {sys.argv[2]}   模块 {sys.argv[4]}   分支 {sys.argv[3]}")
print(f"接口 {ops}   写接口 {writes}   Schema {schemas}\n")
print("\n".join(lines))
PY

if [[ $YES -eq 0 ]]; then
  read -r -p $'\n确认发布? [y/N] ' ans
  [[ "$ans" =~ ^[Yy]$ ]] || { echo "已取消，未写入 Apifox" >&2; exit 0; }
fi

IMPORT_ARGS=(import "${APIFOX_ARGS[@]}" --format openapi --file "$OUT" --overwrite-mode "$OVERWRITE_MODE" --branch "$BRANCH")
if [[ $MAIN -eq 0 && $BRANCH_GIVEN -eq 0 && "$BRANCH_STATE" != "active" ]]; then
  set +e
  CREATE_OUT="$(apifox branch create "${APIFOX_ARGS[@]}" --type ai --name "$BRANCH" --from "$SOURCE_BRANCH" 2>&1)"
  CREATE_CODE=$?
  set -e
  if [[ $CREATE_CODE -ne 0 ]]; then
    echo "$CREATE_OUT" >&2
    die "创建 AI 分支失败: $BRANCH"
  fi
  echo "已创建分支: $BRANCH" >&2
fi
set +e
IMPORT_OUT="$(apifox "${IMPORT_ARGS[@]}" 2>&1)"
IMPORT_CODE=$?
set -e
if [[ $IMPORT_CODE -ne 0 ]]; then
  echo "$IMPORT_OUT" >&2
  grep -q 'Automation caller branch required' <<<"$IMPORT_OUT" && exit 3
  exit 4
fi

python3 - "$IMPORT_OUT" <<'PY'
import json, sys
raw = sys.argv[1]
start = raw.find('{')
d = json.loads(raw[start:]) if start >= 0 else {}
if not d.get('success'):
    sys.exit(f"ERROR: 导入失败: {(d.get('error') or {}).get('message') or raw[:200]}")
item = (d['data'].get('apiCollection') or {}).get('item') or {}
sc = (d['data'].get('schemaCollection') or {}).get('item') or {}
print(f"接口 create={item.get('createCount',0)} update={item.get('updateCount',0)} error={item.get('errorCount',0)}"
      f"  schema create={sc.get('createCount',0)} update={sc.get('updateCount',0)}")
if item.get('errorCount', 0) > 0: sys.exit('ERROR: 导入存在失败项')
PY

LIST_OUT="$(apifox endpoint list "${APIFOX_ARGS[@]}" --branch "$BRANCH" 2>/dev/null)"
BASE_OUT=""
[[ "$BRANCH" != "$SOURCE_BRANCH" ]] && BASE_OUT="$(apifox endpoint list "${APIFOX_ARGS[@]}" --branch "$SOURCE_BRANCH" 2>/dev/null)"
python3 - "$OUT" "$LIST_OUT" "$BASE_OUT" <<'PY'
import json, sys
spec = json.load(open(sys.argv[1], encoding='utf-8'))
def eps(raw):
    if not raw.strip(): return []
    d = json.loads(raw)
    return d.get('data') or []
methods = {'get','post','put','patch','delete','head','options','trace'}
want = {(m.upper(), p) for p, item in spec.get('paths', {}).items() for m in item if m in methods}
# AI 分支只存改动，未改动资源继承自源分支，回读需取并集
have = {(e['method'].upper(), e['path']) for e in eps(sys.argv[2]) + eps(sys.argv[3])}
missing = sorted(want - have)
if missing:
    print(f"ERROR: {len(missing)} 个接口未回读到: {missing[:5]}", file=sys.stderr)
    sys.exit(1)
print(f"回读通过: {len(want)} 个接口全部存在")
PY

echo "完成: 项目 $PROJECT 分支 $BRANCH 产物 $OUT" >&2
[[ $MAIN -eq 0 && $BRANCH_GIVEN -eq 0 ]] && \
  echo "合并预览: apifox merge-request preview --project $PROJECT --from $BRANCH --to $SOURCE_BRANCH" >&2
exit 0
