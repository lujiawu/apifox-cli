# apifox-cli

不启动 Spring，反射扫描 Spring Boot fat jar 上的 RUNTIME 注解（`@Operation` / `@Schema` / Spring MVC），用 swagger-core 反解泛型，静态生成 OpenAPI 3.0.1 JSON，供 Apifox 导入。替代 IDEA 插件手工导出。

技术方案与决策：`docs/design.md`。

## 构建

JDK 8 + Maven：

```bash
mvn package
```

`apifox-pub.sh` 需要 `dist/apifox-cli.jar`：缺失时会自己执行 `mvn -DskipTests package` 并拷贝过去；`publish.sh` 则直接使用 `target/apifox-cli.jar`，缺失时也自动构建。如果 JDK8 不在 PATH，先设置 `JAVA8_HOME` 指向 JDK8 目录。YAML 配置解析需要 Python 的 PyYAML：`pip install pyyaml`（`apifox` CLI 与 `python3` 也是前置依赖）。

## 直接生成 OpenAPI

```bash
java -jar target/apifox-cli.jar \
  --jar /path/to/service/target/service.jar \
  --include com.example.demo.controller \
  --path-prefix demo \
  --server-url https://gateway.example.com \
  --out demo.openapi.json
```

`--path-prefix` 可选，不传则不加前缀；传 `demo` 后 `/system/x` 变为 `/demo/system/x`。`servers` 只来自 `--server-url`。

调试用模式：

```bash
--classes <编译产物目录> --libs <依赖 jar 目录>   # dev 模式，替代 --jar
--class com.example.demo.SomeController         # 精确指定（此时忽略 include/exclude）
--list                                          # 只列命中的 controller，不生成
```

退出码：`0` 成功；`1` 异常；`2` 扫到 0 个 controller。
stdout 只有 JSON；stderr 打一行统计；`--list` 时 stdout 为清单文本。

## 一键发布（`apifox-pub.sh`）

脚本已可软链到 PATH 中的任意位置（例如 `~/.local/bin/apifox-pub.sh`），它自己解析软链定位 `dist/apifox-cli.jar` 和配置文件。

```bash
cd /path/to/business-project
apifox-pub.sh com.example.demo.controller
```

只传 controller 包即可：项目目录默认当前路径，Apifox 项目 ID、路径前缀、模块名和分支从 YAML 配置读取。

配置优先级：命令行参数 > 环境变量 > `~/.config/apifox/config.yml`（或 `$XDG_CONFIG_HOME/apifox/config.yml`）> 仓库内示例配置。

```yaml
# .config/apifox/config.yml（示例，可入库）
defaults:
  source_branch: main
  overwrite_mode: overwrite

projects:
  demo:                       # key = 业务项目目录名
    apifox_project: "123456"  # Apifox 项目 ID
    path_prefix: demo         # 系统路由前缀，可空
    module: demo              # 模块名/文档标题，可空则用目录名
    branch: ai/20261119-from-main-demo  # 固定分支，可空则按日期生成
```

本地真实值放 `~/.config/apifox/config.yml`（仓库之外，不会入库），脚本优先读它；也可以用 `PUB_CONF` 指定其他 YAML 文件。

脚本行为：

1. 找最新 Spring Boot fat jar（Maven `target/` 或 Gradle `build/libs/`）；源码比编译产物新时自动构建（`--no-build` 关闭，`--build` 强制）。
2. 生成 OpenAPI，打印接口数与完整 path 清单。
3. 输入 `y` 确认后才写入；默认写 AI 分支，不污染源分支。AI 分支 24 小时无差异会自动归档，脚本检测到归档后自动换当天的新分支。
4. 导入后回读比对（AI 分支只存差异，因此回读取「分支 ∪ 源分支」）。

| 参数 | 说明 |
|---|---|
| `<controller包>` | 必填，位置参数 1 |
| `<项目目录>` | 可选，位置参数 1 为目录时用；否则默认当前目录 |
| `<apifox项目ID>` / `<前缀>` | 可选位置参数，覆盖 YAML |
| `--branch <name>` | 写指定分支，不创建 |
| `--main` | 直接写源分支（需项目开启外部 AI 编辑权限） |
| `--from <branch>` | AI 分支的源分支，默认取 YAML `defaults.source_branch` |
| `--title <name>` | 覆盖模块名 |
| `--api <METHOD> <PATH>` | 只更新指定接口，可重复；不传则更新全部。路径用带前缀的完整路径，找不到即报错不导入 |
| `--build` / `--no-build` | 强制构建 / 禁用自动构建 |
| `-y, --yes` | 跳过确认 |

| 环境变量 | 作用 |
|---|---|
| `JAVA8_HOME` | JDK8 目录（默认探测 PATH） |
| `PUB_CONF` | YAML 配置路径 |
| `PUB_BUILD_CMD` | 构建命令，默认 `mvn -DskipTests package` |
| `PUB_SOURCE_BRANCH` / `PUB_OVERWRITE_MODE` | 覆盖 YAML defaults |
| `APIFOX_ACCESS_TOKEN` | 可选，Apifox 访问令牌，不落盘 |

退出码：`0` 成功、`1` 参数或构建失败、`2` 没扫到 controller、`3` AI 写入权限受限、`4` 导入或回读失败。

## 完整流程（`publish.sh`）

带构建、质量门禁、AI 分支与回读校验的完整流程，适合 CI：

```bash
export APIFOX_ACCESS_TOKEN=...   # 可选，已登录 apifox CLI 时不需要

./publish.sh \
  --project-dir /path/to/business-project \
  --include com.example.demo.controller \
  --apifox-project 123456 \
  --title demo \
  --system-name demo
```

`--dry-run` 只生成并输出指标，不写 Apifox；`--jar <path>` 直接用现有 fat jar；`--no-build` 跳过构建。

## 基线回归

```bash
./verify.sh generated.openapi.json baseline.json
```

对比 paths / operations / schemas 计数与 tag 清单差异。

## License

MIT
