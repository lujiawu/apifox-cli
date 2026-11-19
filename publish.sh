#!/usr/bin/env bash
# 一键发布：构建 fat jar -> 生成 OpenAPI -> 质量门禁 -> 导入 Apifox -> 回读验证
set -euo pipefail

usage() {
  cat <<'EOF'
用法: publish.sh --project-dir <dir> --include <pkg> --apifox-project <id> [options]

必填:
  --project-dir <dir>        业务项目根目录（含 pom.xml）
  --include <pkg>            controller 根包，可重复
  --apifox-project <id>      Apifox 项目 ID

可选:
  --branch <name>            直接导入到指定分支（不创建 AI 分支）
  --from <branch>            AI 分支的源分支，默认 main
  --main                     直接写源分支，需项目开启外部 AI 编辑权限
  --title <name>             模块名/文档标题，默认取项目目录名
  --module <id|default|new>  目标模块，默认按 title 匹配或新建
  --server-url <url>         写入 OpenAPI servers
  --system-name <name>       路径前缀，如 demo 生成 /demo/system/x；不传则不加前缀
  --jar <path>               直接使用现有 fat jar（隐含 --no-build）
  --no-build                 不执行 mvn，使用最新 fat jar
  --out <file>               产物路径，默认 <project-dir>/target/<title>.openapi.json
  --overwrite-mode <mode>    overwrite|merge|ignore|keepBoth，默认 overwrite
  --dry-run                  只生成并输出指标，不导入
  -h, --help                 显示帮助

环境变量:
  APIFOX_ACCESS_TOKEN        Apifox API 访问令牌，不落盘

退出码: 0 成功 / 1 参数或构建失败 / 2 未扫到 controller / 3 AI 写入权限受限 / 4 导入或回读失败

默认行为：新建或复用 AI 分支 ai/<日期>-from-<源分支>-<title>，导入到该分支，源分支不受影响。
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

PROJECT_DIR="" ; INCLUDE=() ; APIFOX_PROJECT="" ; BRANCH="" ; BRANCH_GIVEN=0 ; FROM="" ; WRITE_MAIN=0 ; TITLE="" ; MODULE=""
SERVER_URL="" ; SYSTEM_NAME="" ; JAR="" ; NO_BUILD=0 ; OUT="" ; OVERWRITE_MODE="overwrite" ; DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-dir) PROJECT_DIR="${2:?}"; shift 2 ;;
    --include) INCLUDE+=("${2:?}"); shift 2 ;;
    --apifox-project) APIFOX_PROJECT="${2:?}"; shift 2 ;;
    --branch) BRANCH="${2:?}"; BRANCH_GIVEN=1; shift 2 ;;
    --from) FROM="${2:?}"; shift 2 ;;
    --main) WRITE_MAIN=1; shift ;;
    --title) TITLE="${2:?}"; shift 2 ;;
    --module) MODULE="${2:?}"; shift 2 ;;
    --server-url) SERVER_URL="${2:?}"; shift 2 ;;
    --system-name) SYSTEM_NAME="${2:?}"; shift 2 ;;
    --jar) JAR="${2:?}"; NO_BUILD=1; shift 2 ;;
    --no-build) NO_BUILD=1; shift ;;
    --out) OUT="${2:?}"; shift 2 ;;
    --overwrite-mode) OVERWRITE_MODE="${2:?}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数: $1（--help 查看用法）" ;;
  esac
done

[[ -n "$PROJECT_DIR" ]] || die "缺少 --project-dir"
[[ ${#INCLUDE[@]} -gt 0 ]] || die "缺少 --include"
[[ -n "$APIFOX_PROJECT" ]] || die "缺少 --apifox-project"
[[ -d "$PROJECT_DIR" ]] || die "目录不存在: $PROJECT_DIR"

PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"
[[ -n "$TITLE" ]] || TITLE="$(basename "$PROJECT_DIR")"
[[ -n "$OUT" ]] || OUT="$PROJECT_DIR/target/$TITLE.openapi.json"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI_JAR="$SCRIPT_DIR/target/apifox-cli.jar"
if [[ ! -f "$CLI_JAR" ]]; then
  echo "未找到 CLI jar，自动构建: $SCRIPT_DIR (mvn -DskipTests package)" >&2
  ( cd "$SCRIPT_DIR" && JAVA_HOME="$JAVA8_HOME" mvn -DskipTests package ) || die "CLI 构建失败"
fi
command -v python3 >/dev/null || die "需要 python3"

# 找最新的 Spring Boot fat jar（含 BOOT-INF/）
find_fat_jar() {
  local best="" best_mtime=0 found=0 f
  while IFS= read -r f; do
    unzip -l "$f" 'BOOT-INF/*' >/dev/null 2>&1 || continue
    found=$((found + 1))
    local mt; mt=$(stat -c %Y "$f")
    if [[ $mt -gt $best_mtime ]]; then best="$f"; best_mtime=$mt; fi
  done < <(find "$PROJECT_DIR" -maxdepth 4 -type f \( -path '*/target/*.jar' -o -path '*/build/libs/*.jar' \) ! -name '*-sources.jar' ! -name '*-javadoc.jar')
  if [[ $found -gt 1 ]]; then
    echo "WARN: 找到 $found 个 fat jar（可重现构建的时间戳不可信）:" >&2
    echo "$best" >&2
    die "请用 --jar 明确指定 fat jar"
  fi
  [[ -n "$best" ]] && printf '%s\n' "$best"
}

if [[ -z "$JAR" ]]; then
  if [[ $NO_BUILD -eq 0 ]]; then
    echo "[1/5] 构建: $BUILD_CMD" >&2
    ( cd "$PROJECT_DIR" && eval "$BUILD_CMD" )
  else
    echo "[1/5] 跳过构建（--no-build）" >&2
  fi
  JAR="$(find_fat_jar)"
  [[ -n "$JAR" ]] || die "未找到含 BOOT-INF/ 的 fat jar，请用 --jar 指定"
fi
echo "[1/5] fat jar: $JAR" >&2

echo "[2/5] 生成 OpenAPI: $OUT" >&2
mkdir -p "$(dirname "$OUT")"
GEN_ARGS=(--jar "$JAR" --title "$TITLE" --out "$OUT")
for pkg in "${INCLUDE[@]}"; do GEN_ARGS+=(--include "$pkg"); done
[[ -n "$SERVER_URL" ]] && GEN_ARGS+=(--server-url "$SERVER_URL")
[[ -n "$SYSTEM_NAME" ]] && GEN_ARGS+=(--path-prefix "$SYSTEM_NAME")
set +e
"$JAVA" -jar "$CLI_JAR" "${GEN_ARGS[@]}"
GEN_CODE=$?
set -e
if [[ $GEN_CODE -eq 2 ]]; then
  die "未扫到 @RestController（检查 --include 包名）"
elif [[ $GEN_CODE -ne 0 ]]; then
  echo "ERROR: 生成失败，退出码 $GEN_CODE" >&2
  exit 1
fi

echo "[3/5] 质量门禁" >&2
python3 - "$OUT" "$SYSTEM_NAME" <<'PY'
import json, sys
p = sys.argv[1]
prefix = sys.argv[2].strip('/')
d = json.load(open(p, encoding='utf-8'))
methods = {'get','post','put','patch','delete','head','options','trace'}
ops = writes = with_body = empty_body = 0
for item in d.get('paths', {}).values():
    for m, op in item.items():
        if m not in methods: continue
        ops += 1
        if m in ('post','put','patch'):
            writes += 1
            rb = op.get('requestBody')
            if rb:
                with_body += 1
                sch = (rb.get('content') or {}).get('application/json', {}).get('schema') or {}
                if sch.get('type') == 'object' and not sch.get('properties'): empty_body += 1
schemas = len((d.get('components') or {}).get('schemas') or {})
print(f"  paths={len(d.get('paths', {}))} operations={ops} schemas={schemas} writes={writes} withBody={with_body} emptyObjectBodies={empty_body}")
if ops == 0: sys.exit('ERROR: 生成结果没有任何 operation')
if empty_body > 0: print(f"  WARN: {empty_body} 个写接口 body 是空对象", file=sys.stderr)
if prefix:
    bad = [p for p in d.get('paths', {}) if not (p == '/' + prefix or p.startswith('/' + prefix + '/'))]
    if bad: sys.exit(f"ERROR: {len(bad)} 个 path 缺少前缀 /{prefix}，例如 {bad[0]}")
    print(f"  前缀校验通过: 全部 path 以 /{prefix} 开头")
PY

if [[ $DRY_RUN -eq 1 ]]; then
  echo "[4/5] --dry-run，跳过导入" >&2
  echo "[5/5] 产物: $OUT" >&2
  exit 0
fi

command -v apifox >/dev/null || die "未安装 apifox CLI"

SOURCE_BRANCH="${FROM:-main}"
APIFOX_ARGS=(--project "$APIFOX_PROJECT")
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
    print("absent")' "$1" || true
}

if [[ -z "$BRANCH" ]]; then
  if [[ $WRITE_MAIN -eq 1 ]]; then
    BRANCH="$SOURCE_BRANCH"
  else
    BRANCH="ai/$(date +%Y%m%d)-from-${SOURCE_BRANCH//\//-}-$TITLE"
    STATE="$(branch_state "$BRANCH")"
    [[ -n "$STATE" ]] || STATE="absent"
    if [[ "$STATE" == "archived" ]]; then
      echo "[4/5] 分支已归档，改用新分支: $BRANCH" >&2
      base="ai/$(date +%Y%m%d)-from-${SOURCE_BRANCH//\//-}-$TITLE"
      BRANCH="$base"; n=1
      while [[ "$(branch_state "$BRANCH")" == "archived" ]]; do
        n=$((n + 1)); BRANCH="$base-$n"
        [[ $n -gt 20 ]] && die "找不到可用分支名（$base-*）"
      done
      STATE="$(branch_state "$BRANCH")"
      [[ -n "$STATE" ]] || STATE="absent"
    fi
    if [[ "$STATE" == "active" ]]; then
      echo "[4/5] 复用 AI 分支: $BRANCH" >&2
    else
      echo "[4/5] 创建 AI 分支: $BRANCH (from $SOURCE_BRANCH)" >&2
      set +e
      CREATE_OUT="$(apifox branch create "${APIFOX_ARGS[@]}" --type ai --name "$BRANCH" --from "$SOURCE_BRANCH" 2>&1)"
      CREATE_CODE=$?
      set -e
      if [[ $CREATE_CODE -ne 0 ]]; then
        echo "$CREATE_OUT" >&2
        die "创建 AI 分支失败（检查源分支 $SOURCE_BRANCH 是否存在）"
      fi
    fi
  fi
fi

IMPORT_ARGS=(import "${APIFOX_ARGS[@]}" --format openapi --file "$OUT" --overwrite-mode "$OVERWRITE_MODE" --branch "$BRANCH")
[[ -n "$MODULE" ]] && IMPORT_ARGS+=(--module-map "$TITLE=$MODULE")

echo "[4/5] 导入 Apifox 项目 $APIFOX_PROJECT (分支 $BRANCH)" >&2
set +e
IMPORT_OUT="$(apifox "${IMPORT_ARGS[@]}" 2>&1)"
IMPORT_CODE=$?
set -e
if [[ $IMPORT_CODE -ne 0 ]]; then
  echo "$IMPORT_OUT" >&2
  if grep -q 'Automation caller branch required' <<<"$IMPORT_OUT"; then
    cat >&2 <<EOF
AI 写入被权限拦截：分支 $BRANCH 不允许 AI 直接写。
  1) 不传 --main / --branch，让脚本建 AI 分支（默认行为）
  2) 或 Apifox 客户端 2.8.32+ 开启「项目设置 - 功能设置 - 外部 AI 编辑权限」
EOF
    exit 3
  fi
  exit 4
fi

python3 - "$IMPORT_OUT" <<'PY'
import json, sys
raw = sys.argv[1]
start = raw.find('{')
d = json.loads(raw[start:]) if start >= 0 else {}
if not d.get('success'):
    msg = (d.get('error') or {}).get('message') or d
    sys.exit(f"ERROR: 导入失败: {msg}")
item = (d['data'].get('apiCollection') or {}).get('item') or {}
schema = (d['data'].get('schemaCollection') or {}).get('item') or {}
print(f"  接口: create={item.get('createCount',0)} update={item.get('updateCount',0)} ignore={item.get('ignoreCount',0)} error={item.get('errorCount',0)}")
print(f"  schema: create={schema.get('createCount',0)} update={schema.get('updateCount',0)}")
if item.get('errorCount', 0) > 0: sys.exit('ERROR: 导入存在失败项')
if item.get('ignoreCount', 0) > 0: print('  WARN: 存在被忽略的接口，检查是否导入到了预期模块/项目', file=sys.stderr)
PY

echo "[5/5] 回读验证" >&2
LIST_ARGS=(endpoint list "${APIFOX_ARGS[@]}")
[[ -n "$BRANCH" ]] && LIST_ARGS+=(--branch "$BRANCH")
LIST_OUT="$(apifox "${LIST_ARGS[@]}" 2>/dev/null || true)"
BASE_LIST=""
[[ "$BRANCH" != "$SOURCE_BRANCH" ]] && BASE_LIST="$(apifox endpoint list "${APIFOX_ARGS[@]}" --branch "$SOURCE_BRANCH" 2>/dev/null || true)"
python3 - "$OUT" "$LIST_OUT" "$BASE_LIST" <<'PY'
import json, sys
spec = json.load(open(sys.argv[1], encoding='utf-8'))
def eps(raw):
    if not raw.strip(): return []
    d = json.loads(raw)
    if not d.get('success'): return []
    return d.get('data') or []
methods = {'get','post','put','patch','delete','head','options','trace'}
want = {(m.upper(), p) for p, item in spec.get('paths', {}).items() for m in item if m in methods}
# AI 分支只存改动，未改动资源继承自源分支
have = {(e['method'].upper(), e['path']) for e in eps(sys.argv[2]) + eps(sys.argv[3])}
missing = sorted(want - have)
if missing:
    print(f"  ERROR: {len(missing)} 个接口未回读到:", file=sys.stderr)
    for m, p in missing[:10]: print(f"    {m} {p}", file=sys.stderr)
    sys.exit(1)
print(f"  回读通过: {len(want)} 个 method+path 全部存在")
PY

echo "完成: project=$APIFOX_PROJECT title=$TITLE branch=$BRANCH artifact=$OUT" >&2
if [[ $WRITE_MAIN -eq 0 && $BRANCH_GIVEN -eq 0 ]]; then
  echo "改动在 AI 分支上，源分支未变。确认后合并: apifox merge-request preview --project $APIFOX_PROJECT --from $BRANCH --to $SOURCE_BRANCH" >&2
fi
