package com.example.apifox;

import com.example.apifox.ControllerReader;
import io.swagger.v3.oas.models.OpenAPI;
import io.swagger.v3.oas.models.PathItem;
import io.swagger.v3.oas.models.Paths;

import java.io.File;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;

/**
 * 入口与参数解析。用法见 README；退出码 0 成功 / 1 异常 / 2 扫到 0 个 controller。
 */
public final class OpenApiCli {

    static class CliError extends RuntimeException {
        final int code;
        CliError(int code, String msg) { super(msg); this.code = code; }
    }

    static final class Opts {
        File jar;
        File classes;
        File libs;
        List<String> includes = new ArrayList<String>();
        List<String> excludes = new ArrayList<String>();
        List<String> explicit = new ArrayList<String>();
        boolean list;
        String serverUrl, title, version, out, pathPrefix;
    }

    public static void main(String[] args) {
        long start = System.currentTimeMillis();
        try {
            System.exit(run(args, start));
        } catch (CliError e) {
            if (e.getMessage() != null) System.err.println("ERROR: " + e.getMessage());
            System.exit(e.code);
        } catch (Throwable t) {
            t.printStackTrace();
            System.exit(1);
        }
    }

    static int run(String[] args, long start) throws Exception {
        Opts o = parse(args);

        long t0 = System.currentTimeMillis();
        ArchiveLoader.Load load = o.jar != null
                ? ArchiveLoader.fat(o.jar)
                : ArchiveLoader.dev(o.classes, o.libs);
        long loadMs = System.currentTimeMillis() - t0;

        List<Class<?>> controllers = ControllerScanner.find(load, o.includes, o.excludes, o.explicit);

        if (o.list) {
            for (Class<?> c : controllers) {
                System.out.println(String.format("%-70s ops=%-3d tag=%s",
                        c.getName(), ControllerReader.countOps(c), ControllerReader.tagOf(c)));
            }
            return controllers.isEmpty() ? 2 : 0;
        }
        if (controllers.isEmpty()) {
            System.err.println("no @RestController matched");
            return 2;
        }

        File out = o.out == null ? null : new File(o.out);
        String title = o.title != null ? o.title : baseName(o);
        String version = o.version != null ? o.version : "1.0.0";
        ControllerReader.DocResult r = ControllerReader.build(controllers, o.serverUrl, title, version);
        if (o.pathPrefix != null) prefixPaths(r.api, o.pathPrefix);
        DocWriter.write(r.api, out);
        DocWriter.stats(controllers.size(), r.paths, r.operations, r.schemas, r.unnamed, loadMs, start);
        return 0;
    }

    /** 网关路由前缀：/demo + /system/x -> /demo/system/x；已带前缀则不重复 */
    private static void prefixPaths(OpenAPI api, String raw) {
        String prefix = raw.trim().replaceAll("^/+|/+$", "");
        if (prefix.isEmpty() || api.getPaths() == null) return;
        String head = "/" + prefix;
        Paths out = new Paths();
        for (Map.Entry<String, PathItem> e : new TreeMap<String, PathItem>(api.getPaths()).entrySet()) {
            String p = e.getKey();
            boolean has = p.equals(head) || p.startsWith(head + "/");
            out.put(has ? p : head + p, e.getValue());
        }
        api.setPaths(out);
    }

    static String baseName(Opts o) {
        String n = o.jar != null ? o.jar.getName() : serviceNameOf(o.classes);
        int i = n.lastIndexOf('.');
        return i > 0 ? n.substring(0, i) : n;
    }

    /** --classes 也可能是 BOOT-INF/classes 这类目录，向上找一级生成 title */
    private static String serviceNameOf(File classes) {
        File p = classes.getParentFile();
        if (p != null && ("classes".equals(p.getName()) || "BOOT-INF".equals(p.getName()))
                && p.getParentFile() != null) {
            return p.getParentFile().getName();
        }
        return classes.getName();
    }

    private static Opts parse(String[] args) {
        Opts o = new Opts();
        for (int i = 0; i < args.length; i++) {
            String a = args[i];
            if ("--list".equals(a)) { o.list = true; continue; }
            if ("--out".equals(a)) o.out = value(a, args, ++i);
            else if ("--server-url".equals(a)) o.serverUrl = value(a, args, ++i);
            else if ("--title".equals(a)) o.title = value(a, args, ++i);
            else if ("--version".equals(a)) o.version = value(a, args, ++i);
            else if ("--path-prefix".equals(a)) o.pathPrefix = value(a, args, ++i);
            else if ("--jar".equals(a)) o.jar = file(value(a, args, ++i));
            else if ("--classes".equals(a)) o.classes = file(value(a, args, ++i));
            else if ("--libs".equals(a)) o.libs = file(value(a, args, ++i));
            else if ("--include".equals(a)) o.includes.add(value(a, args, ++i));
            else if ("--exclude".equals(a)) o.excludes.add(value(a, args, ++i));
            else if ("--class".equals(a)) o.explicit.add(value(a, args, ++i));
            else throw new CliError(1, "unknown option: " + a + "\n" + usage());
        }
        if (o.jar != null && o.classes != null)
            throw new CliError(1, "--jar 与 --classes 二选一\n" + usage());
        if (o.jar == null && o.classes == null)
            throw new CliError(1, "必须提供 --jar 或 --classes\n" + usage());
        if (o.explicit.isEmpty() && o.includes.isEmpty())
            throw new CliError(1, "必须提供 --include（或用 --class 精确指定）\n" + usage());
        return o;
    }

    private static String value(String flag, String[] args, int i) {
        if (i >= args.length || args[i].startsWith("--"))
            throw new CliError(1, flag + " 缺少值\n" + usage());
        return args[i];
    }

    private static File file(String p) {
        File f = new File(p);
        if (!f.exists())
            throw new CliError(1, "路径不存在: " + p);
        return f;
    }

    static String usage() {
        return "usage: java -jar apifox-cli.jar --jar <fat.jar> | --classes <dir> [--libs <dir>]\n"
             + "       --include <pkg>... [--exclude <pkg>...] [--class <fqcn>...]\n"
             + "       [--list] [--out <file>] [--server-url <url>] [--path-prefix <seg>] [--title t] [--version v]";
    }
}
