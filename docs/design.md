# apifox-cli 技术方案

## 目标

独立小工具：不启动 Spring、不改业务代码，从编译产物（Spring Boot fat jar 或 classes 目录）反射扫描运行期注解，静态生成 OpenAPI 3.0.1 JSON，供 Apifox 导入。

## 模块结构

单 Maven 模块，shade 打成可执行 jar：

```
src/main/java/com/example/apifox/
  OpenApiCli.java        入口、参数解析、退出码
  ArchiveLoader.java     fat jar / dev 目录 -> URLClassLoader（父优先）
  ControllerScanner.java entry 枚举 -> 包过滤 -> @RestController
  ControllerReader.java  注解 -> Operation / Parameters / RequestBody / Responses
  DocWriter.java         TreeMap 排序序列化 + stdout JSON + stderr 统计
```

依赖：swagger-core / swagger-models / swagger-annotations、spring-web（仅注解）、spring-boot-loader（嵌套 jar URL handler）、jackson、jakarta.validation-api、slf4j-nop。

## CLI 参数

| 参数 | 说明 |
|---|---|
| `--jar <path>` | 输入一（主线）：Spring Boot fat jar |
| `--classes <dir> --libs <dir>` | 输入二（dev 模式），二选一必填 |
| `--include <pkg>` | 包前缀，必填（`--class` 指定后忽略），可重复 |
| `--exclude <pkg>` | 优先于 include，可重复 |
| `--class <fqcn>` | 精确指定，可重复 |
| `--list` | 只列命中的 controller，不生成 |
| `--server-url <url>` / `--title` / `--version` | 填 Info 与 servers |
| `--path-prefix <seg>` | 统一给 paths 加路由前缀（`demo` -> `/demo/system/x`），不传不加 |
| `--out <file>` | 默认 stdout |

退出码：`0` 成功；`1` 异常；`2` 扫到 0 个 controller。stdout 只有 JSON，stderr 一行统计。

## fat jar 扫描

1. `ZipFile` 只枚举 entry 名（`BOOT-INF/classes/**` 与 `BOOT-INF/lib/*.jar`），不解压。
2. include 用路径前缀在 entry 层先筛，天然带包边界。
3. 用 `spring-boot-loader` 注册嵌套 jar URL handler，`URLClassLoader` 挂上 classes 与依赖 jar；父 loader 为 CLI 自身（父优先），保证注解库解析顺序稳定。
4. `Class.forName(name, false, loader)` 不初始化静态块；单类加载异常捕获后跳过。
5. 跳过 `$` 内部类、`package-info`、`module-info`；只认 `@RestController`。

## 路径、参数与响应

- 路径：类级 `@RequestMapping`（value 与 path 合并取第一个非空）作前缀；方法支持 `@GetMapping` / `@PostMapping` / `@PutMapping` / `@DeleteMapping` / `@PatchMapping` / `@RequestMapping`。
- 元信息：`@Tag(name)` -> tags（按 FQCN 排序保证稳定）；`@Operation` summary / description / deprecated；类或方法 `@Hidden` 跳过。
- 参数：`@PathVariable` -> path，`@RequestParam` -> query，`@RequestHeader` -> header，`@CookieValue` -> cookie，`@RequestBody` -> body；显式 `@Parameter(in=QUERY/HEADER)` 按其声明；无注解的非简单类型展开为 query 字段。
- model：由 swagger-core `ModelConverters` 处理泛型、`@Schema` 与校验注解，注册进 `components.schemas` 后返回 `$ref`；简单类型走内置映射。
- 响应：`ResponseEntity<T>` 解包为 `T`；`void` -> 200 无 content。
- 不写 `operationId`（Apifox 按 path + method 匹配）；`servers` 只来自 `--server-url`，路径前缀只来自 `--path-prefix`；paths 与 schemas 按字母序输出，保证产物稳定。

## 设计决策

1. **独立仓**：工具服务多个 Spring Boot 项目，业务仓零侵入。
2. **`--include` 必填**：防止全量扫描导致意外 controller 与类冲突；忘传时直接报错。
3. **OpenAPI 3.0.1 JSON，不生成 YAML**：覆盖 Apifox 导入，少一种格式少一条维护面。
4. **反射注解而非 springdoc `/v3/api-docs`**：业务仓不需要加依赖、起应用，CI 只读编译产物。
5. **不内置 Apifox 推送逻辑**：token 交给 CI secret；推送交给 `apifox` CLI 脚本层，生成与发布解耦。
6. **嵌套 jar loader**：避免解压临时目录，代价是不支持 Boot 3 的打包结构（Non-goal）。
7. **父优先的类加载**：注解库版本以 CLI 自带为准，避免业务依赖漂移影响解析。

## 风险与边界

| 风险 | 缓解 |
|---|---|
| 参数名未开 `-parameters` 时退化为 arg0 | stderr 的 `unnamed=N` 暴露缺口；业务端开启 `-parameters` 可根治 |
| 服务升级 swagger-annotations 后新注解属性静默丢失 | CLI 与服务版本对齐；`verify.sh` 计数与差异基线兜底 |
| spring-boot-loader 与 Boot 版本绑定 | 固定版本；Boot 3 明确不支持 |
| 同一 path + method 冲突后写覆盖 | 生成前检查产物；发布前预览清单人工确认 |

## Non-goals

- 不生成 YAML、不合并多个服务输出
- Java CLI 内不做 Apifox 推送
- 不支持 Boot 3.x 打包、不写 operationId
- 不做 Maven plugin / Gradle 插件
