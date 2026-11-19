package com.example.apifox;

import org.springframework.boot.loader.jar.JarFile;

import java.io.File;
import java.net.URL;
import java.net.URLClassLoader;
import java.util.ArrayList;
import java.util.List;
import java.util.zip.ZipFile;

/**
 * 输入源：Spring Boot fat jar（嵌套 jar 走 spring-boot-loader 的 URL handler）或 dev 的 classes+libs 目录。
 * 父 loader = CLI 自身，父优先复现 POC 平铺 classpath 的解析顺序（swagger/jackson 以 CLI 版本为准）。
 */
final class ArchiveLoader {

    static final class Load {
        final ClassLoader loader;
        final List<String> classNames; // 候选 fqcn，未过滤
        Load(ClassLoader loader, List<String> classNames) {
            this.loader = loader;
            this.classNames = classNames;
        }
    }

    private ArchiveLoader() {}

    static Load fat(File jar) throws Exception {
        JarFile.registerUrlProtocolHandler();
        ZipFile zf = new ZipFile(jar);
        List<URL> urls = new ArrayList<URL>();
        List<String> classNames = new ArrayList<String>();
        List<String> libs = new ArrayList<String>();
        URL base = jar.toURI().toURL();
        try {
            java.util.Enumeration<? extends java.util.zip.ZipEntry> e = zf.entries();
            while (e.hasMoreElements()) {
                String n = e.nextElement().getName();
                if (n.startsWith("BOOT-INF/classes/") && n.endsWith(".class")) {
                    classNames.add(toFqcn(n.substring("BOOT-INF/classes/".length())));
                } else if (n.startsWith("BOOT-INF/lib/") && n.endsWith(".jar")) {
                    urls.add(new URL("jar:" + base + "!/" + n + "!/"));
                    libs.add(n);
                }
            }
            // classes 放最前，类查找顺序与 Boot 运行时一致
            urls.add(0, new URL("jar:" + base + "!/BOOT-INF/classes/"));
        } finally {
            zf.close();
        }
        // controller 常在业务 lib jar 里，entry 名也要参与筛选；
        // 通过已注册 handler 枚举嵌套 jar 不做解压
        for (String n : libs) {
            java.util.jar.JarFile nf = ((java.net.JarURLConnection)
                    new URL("jar:" + base + "!/" + n + "!/").openConnection()).getJarFile();
            java.util.Enumeration<java.util.jar.JarEntry> e2 = nf.entries();
            while (e2.hasMoreElements()) { // 不 close：handler 缓存该 JarFile，供后续 ClassLoader 复用
                String en = e2.nextElement().getName();
                if (en.endsWith(".class")) classNames.add(toFqcn(en));
            }
        }
        return new Load(loader(urls), classNames);
    }

    static Load dev(File classes, File libs) throws Exception {
        List<URL> urls = new ArrayList<URL>();
        List<String> classNames = new ArrayList<String>();
        File root = classes.getCanonicalFile();
        urls.add(new URL(root.toURI().toString() + "/"));
        Walk.walk(root, root, classNames);
        if (libs != null) {
            File[] jars = libs.listFiles();
            if (jars != null) for (File j : jars) {
                if (!j.getName().endsWith(".jar")) continue;
                urls.add(j.toURI().toURL());
                ZipFile zj = new ZipFile(j); // lib jar 里的类也要参与筛选（controller 可能在业务 jar 里）
                try {
                    java.util.Enumeration<? extends java.util.zip.ZipEntry> e = zj.entries();
                    while (e.hasMoreElements()) {
                        String en = e.nextElement().getName();
                        if (en.endsWith(".class")) classNames.add(toFqcn(en));
                    }
                } finally {
                    zj.close();
                }
            }
        }
        return new Load(loader(urls), classNames);
    }

    private static ClassLoader loader(List<URL> urls) {
        URL[] u = urls.toArray(new URL[0]);
        return new URLClassLoader(u, OpenApiCli.class.getClassLoader());
    }

    private static String toFqcn(String entry) {
        return entry.substring(0, entry.length() - ".class".length()).replace('/', '.');
    }

    /** 最小文件递归遍历，root 固定用于计算包名 */
    private static final class Walk {
        static void walk(File root, File dir, List<String> names) {
            File[] fs = dir.listFiles();
            if (fs == null) return;
            for (File f : fs) {
                if (f.isDirectory()) walk(root, f, names);
                else if (f.getName().endsWith(".class"))
                    names.add(toFqcn(rootRelative(root, f).replace(File.separatorChar, '/')));
            }
        }
        private static String rootRelative(File root, File f) {
            String p = f.getPath(), r = root.getPath();
            return p.substring(r.length() + (r.endsWith(File.separator) ? 0 : 1));
        }
    }
}
