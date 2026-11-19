package com.example.apifox;

import org.springframework.web.bind.annotation.RestController;

import java.util.ArrayList;
import java.util.List;

/**
 * entry 名 → 前缀过滤 → Class.forName(false) → @RestController。
 * 过滤全部在 fqcn 层做（带包边界），只 load 命中的类。
 */
final class ControllerScanner {

    private ControllerScanner() {}

    static List<Class<?>> find(ArchiveLoader.Load load, List<String> includes,
                               List<String> excludes, List<String> explicit) {
        List<Class<?>> out = new ArrayList<Class<?>>();

        // dev 模式 classes 目录与 lib jar 可能重复枚举同一类，去重
        java.util.LinkedHashSet<String> candidates = new java.util.LinkedHashSet<String>();
        for (String fqn : load.classNames) {
            if (isInternal(fqn)) continue;
            if (!explicit.isEmpty()) candidates.add(fqn); // 精确模式：忽略 include/exclude
            else if (matches(fqn, includes, excludes)) candidates.add(fqn);
        }

        if (!explicit.isEmpty()) { // 显式给定：按用户顺序，load 失败要报错
            for (String fqn : explicit) {
                out.add(load0(fqn, load.loader, true));
            }
            return out;
        }
        for (String fqn : candidates) {
            Class<?> c = load0(fqn, load.loader, false);
            if (c != null && c.getAnnotation(RestController.class) != null
                    && !java.lang.reflect.Modifier.isAbstract(c.getModifiers())) {
                out.add(c);
            }
        }
        return out;
    }

    private static Class<?> load0(String fqn, ClassLoader loader, boolean loud) {
        try {
            return Class.forName(fqn, false, loader);
        } catch (Throwable t) {
            if (loud) throw new OpenApiCli.CliError(1, "加载失败: " + fqn + " -> " + t);
            return null;
        }
    }

    static boolean isInternal(String fqn) {
        return fqn.contains("$") || fqn.endsWith(".package-info") || fqn.equals("module-info");
    }

    /** include 命中：exclude 优先 */
    static boolean matches(String fqn, List<String> includes, List<String> excludes) {
        for (String x : excludes) if (in(fqn, x)) return false;
        for (String i : includes) if (in(fqn, i)) return true;
        return false;
    }

    private static boolean in(String fqn, String prefix) {
        return fqn.equals(prefix) || fqn.startsWith(prefix + ".");
    }
}
