package com.example.apifox;

import io.swagger.v3.core.converter.ModelConverters;
import io.swagger.v3.oas.annotations.Hidden;
import io.swagger.v3.oas.annotations.enums.ParameterIn;
import io.swagger.v3.oas.models.Components;
import io.swagger.v3.oas.models.OpenAPI;
import io.swagger.v3.oas.models.Operation;
import io.swagger.v3.oas.models.PathItem;
import io.swagger.v3.oas.models.Paths;
import io.swagger.v3.oas.models.info.Info;
import io.swagger.v3.oas.models.media.Content;
import io.swagger.v3.oas.models.media.MediaType;
import io.swagger.v3.oas.models.media.Schema;
import io.swagger.v3.oas.models.parameters.Parameter;
import io.swagger.v3.oas.models.responses.ApiResponse;
import io.swagger.v3.oas.models.responses.ApiResponses;
import io.swagger.v3.oas.models.servers.Server;
import io.swagger.v3.oas.models.tags.Tag;
import org.springframework.web.bind.annotation.CookieValue;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PatchMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestMethod;
import org.springframework.web.bind.annotation.RequestParam;

import java.lang.annotation.Annotation;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.lang.reflect.ParameterizedType;
import java.lang.reflect.Type;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;
import java.util.Deque;
import java.util.ArrayDeque;
import java.util.HashSet;
import java.util.Set;

/**
 * 注解 → OpenAPI。POC (StaticOpenApi) 平移 + 修补：
 * 接口方法、@RequestHeader/@CookieValue/@ModelAttribute、path 别名、ResponseEntity/void、@Hidden、servers。
 */
final class ControllerReader {

    static final class DocResult {
        OpenAPI api;
        int paths, operations, schemas, unnamed;
    }

    private final OpenAPI api = new OpenAPI();
    private final Components components = new Components();
    private final ModelConverters converters = ModelConverters.getInstance();
    private int unnamed, operations;

    private ControllerReader() {}

    static DocResult build(List<Class<?>> controllers, String serverUrl, String title, String version) {
        ControllerReader r = new ControllerReader();
        r.generate(controllers, serverUrl, title, version);
        DocResult res = new DocResult();
        res.api = r.api;
        res.paths = r.api.getPaths() == null ? 0 : r.api.getPaths().size();
        res.operations = r.operations;
        res.schemas = r.components.getSchemas() == null ? 0 : r.components.getSchemas().size();
        res.unnamed = r.unnamed;
        return res;
    }

    private void generate(List<Class<?>> controllers, String serverUrl, String title, String version) {
        api.setInfo(new Info().title(title).version(version));
        api.setComponents(components);
        if (serverUrl != null) {
            api.setServers(new ArrayList<Server>(Collections.singleton(new Server().url(serverUrl))));
        }

        List<Class<?>> sorted = new ArrayList<Class<?>>(controllers);
        Collections.sort(sorted, new Comparator<Class<?>>() {
            public int compare(Class<?> a, Class<?> b) { return a.getName().compareTo(b.getName()); }
        });

        List<Tag> tags = new ArrayList<Tag>();
        for (Class<?> c : sorted) {
            tags.add(new Tag().name(tagOf(c)));
            scan(c);
        }
        if (!tags.isEmpty()) api.setTags(tags);

        // paths / schemas 字母序输出，保证 git diff 稳定
        if (api.getPaths() != null) {
            TreeMap<String, PathItem> sorted2 = new TreeMap<String, PathItem>(api.getPaths());
            Paths p = new Paths();
            p.putAll(sorted2);
            api.setPaths(p);
        }
        if (components.getSchemas() != null) {
            components.setSchemas(new TreeMap<String, Schema>(components.getSchemas()));
        }
    }

    static String tagOf(Class<?> c) {
        io.swagger.v3.oas.annotations.tags.Tag t = classAnn(io.swagger.v3.oas.annotations.tags.Tag.class, c);
        return t != null && !t.name().isEmpty() ? t.name() : c.getSimpleName();
    }

    /* ---------------- 扫描 ---------------- */

    private void scan(Class<?> clazz) {
        if (classAnn(Hidden.class, clazz) != null) return; // 跳过隐藏 controller
        String base = classBase(clazz);
        String tag = tagOf(clazz);

        for (Method m : operationMethods(clazz)) {
            io.swagger.v3.oas.annotations.Operation ann = findAnn(io.swagger.v3.oas.annotations.Operation.class, m, clazz);
            if (ann == null && findAnn(Hidden.class, m, clazz) != null) continue; // @Hidden 方法
            if (ann != null && ann.hidden()) continue;

            for (Map.Entry<PathItem.HttpMethod, List<String>> e : mappings(m, clazz).entrySet()) {
                for (String sub : e.getValue()) {
                    addOperation(clazz, base, sub, e.getKey(), m, ann, tag);
                }
            }
        }
    }

    private void addOperation(Class<?> clazz, String base, String sub, PathItem.HttpMethod verb,
                              Method m, io.swagger.v3.oas.annotations.Operation ann, String tag) {
        Operation op = new Operation();
        String summary = ann != null ? ann.summary() : m.getName();
        if (ann != null && !ann.description().isEmpty()) op.setDescription(ann.description());
        if (ann != null && ann.deprecated()) op.setDeprecated(true);
        if (summary == null || summary.isEmpty()) summary = m.getName();
        op.setSummary(summary);
        op.addTagsItem(tag);

        readParams(m, clazz, op);
        readBody(m, op);
        readResponse(m, op);

        Paths paths = api.getPaths();
        if (paths == null) { paths = new Paths(); api.setPaths(paths); }
        String path = join(base, sub);
        PathItem item = paths.get(path);
        if (item == null) item = new PathItem();
        item.operation(verb, op);
        paths.addPathItem(path, item);
        operations++;
    }

    /** 类级 @RequestMapping 前缀（value + path 合并取第一个非空），含继承链 */
    private static String classBase(Class<?> clazz) {
        RequestMapping rm = classAnn(RequestMapping.class, clazz);
        if (rm == null) return "";
        for (String s : rm.value()) if (!s.isEmpty()) return s;
        for (String s : rm.path()) if (!s.isEmpty()) return s;
        return "";
    }

    /* ---------------- 方法集合（含接口方法） ---------------- */

    /**
     * 类自身方法优先，补充接口/抽象父类上的声明（POC 缺口 1）。
     * 类覆盖接口方法且自身无注解时，回退到接口上带注解的版本（Spring 行为）。
     */
    static List<Method> operationMethods(Class<?> clazz) {
        LinkedHashMap<String, Method> map = new LinkedHashMap<String, Method>();
        collect(clazz.getDeclaredMethods(), map);
        Set<Class<?>> seen = new HashSet<Class<?>>(); // 防接口菱形重复

        Deque<Class<?>> q = new ArrayDeque<Class<?>>();
        Class<?> s = clazz;
        while (s != null && s != Object.class) {
            push(s, q, seen);
            s = s.getSuperclass();
        }
        while (!q.isEmpty()) {
            Class<?> t = q.poll();
            collect(t.getDeclaredMethods(), map);
            push(t, q, seen);
        }
        List<Method> out = new ArrayList<Method>();
        for (Method m : map.values()) { // 只可能来自类自身或接口，见 collect
            if (Modifier.isStatic(m.getModifiers()) || m.isSynthetic() || m.isBridge()) continue;
            out.add(effective(m, clazz));
        }
        return out;
    }

    private static void collect(Method[] ms, LinkedHashMap<String, Method> map) {
        for (Method m : ms) {
            // 桥接/合成方法必须在占位前跳过：它可能与真实方法同签名，先占位会把带注解的真实方法挤掉
            if (m.isSynthetic() || m.isBridge()) continue;
            String key = m.getName() + "#" + Arrays.toString(m.getParameterTypes());
            if (!map.containsKey(key)) map.put(key, m);
        }
    }

    private static void push(Class<?> t, Deque<Class<?>> q, Set<Class<?>> seen) {
        for (Class<?> i : t.getInterfaces()) if (seen.add(i)) q.add(i);
    }

    /** 无 mapping 注解时，取超类/接口同签名带注解的方法（类覆盖接口方法的场景） */
    private static Method effective(Method m, Class<?> from) {
        if (hasMapping(m) || findAnn(io.swagger.v3.oas.annotations.Operation.class, m, from) != null) return m;
        for (Class<?> t : hierarchyOf(from)) {
            if (t == from) continue;
            try {
                Method alt = t.getDeclaredMethod(m.getName(), m.getParameterTypes());
                if (hasMapping(alt)) return alt;
            } catch (NoSuchMethodException ignore) {
                // 该层级没有同签名方法，继续
            }
        }
        return m;
    }

    private static boolean hasMapping(Method m) {
        return m.getAnnotation(GetMapping.class) != null || m.getAnnotation(PostMapping.class) != null
                || m.getAnnotation(PutMapping.class) != null || m.getAnnotation(DeleteMapping.class) != null
                || m.getAnnotation(PatchMapping.class) != null || m.getAnnotation(RequestMapping.class) != null;
    }

    /* ---------------- 注解查找（含继承链，Spring 的 merged 语义简化版） ---------------- */

    /** 方法注解：直接读，读不到沿 declaringClass 的超类+接口找同签名方法（@Inherited 注解不适用方法，Spring 用 find 语义） */
    static <A extends Annotation> A findAnn(Class<A> type, Method m, Class<?> start) {
        A a = m.getAnnotation(type);
        if (a != null) return a;
        for (Class<?> t : hierarchyOf(m.getDeclaringClass())) {
            try {
                Method alt = t.getDeclaredMethod(m.getName(), m.getParameterTypes());
                A ann = alt.getAnnotation(type);
                if (ann != null) return ann;
            } catch (NoSuchMethodException ignore) { /* 不同层级，继续 */ }
        }
        for (Class<?> t : hierarchyOf(start)) {
            if (t == m.getDeclaringClass()) continue;
            try {
                Method alt = t.getDeclaredMethod(m.getName(), m.getParameterTypes());
                A ann = alt.getAnnotation(type);
                if (ann != null) return ann;
            } catch (NoSuchMethodException ignore) { /* 不同层级，继续 */ }
        }
        return null;
    }

    /** 类注解：直接读 + 超类链 */
    static <A extends Annotation> A classAnn(Class<A> type, Class<?> c) {
        A a = c.getAnnotation(type);
        if (a != null) return a;
        for (Class<?> t = c.getSuperclass(); t != null && t != Object.class; t = t.getSuperclass()) {
            a = t.getAnnotation(type);
            if (a != null) return a;
        }
        return null;
    }

    /** BFS：类 → 超类链 → 接口及其父接口；去掉 Object */
    static List<Class<?>> hierarchyOf(Class<?> c) {
        List<Class<?>> out = new ArrayList<Class<?>>();
        Deque<Class<?>> q = new ArrayDeque<Class<?>>();
        Set<Class<?>> seen = new HashSet<Class<?>>();
        q.add(c);
        while (!q.isEmpty()) {
            Class<?> t = q.poll();
            if (t == null || t == Object.class) continue;
            if (seen.add(t)) out.add(t);
            if (t.getSuperclass() != null) q.add(t.getSuperclass());
            for (Class<?> i : t.getInterfaces()) q.add(i);
        }
        return out;
    }

    /* ---------------- 路径 ---------------- */

    /**
     * 方法 mapping：@XxxMapping / @RequestMapping。
     * value + path 合并（POC 缺口 3）；@RequestMapping 无 method 默认 GET。
     */
    static Map<PathItem.HttpMethod, List<String>> mappings(Method m, Class<?> start) {
        LinkedHashMap<PathItem.HttpMethod, List<String>> r = new LinkedHashMap<PathItem.HttpMethod, List<String>>();
        GetMapping g = findAnn(GetMapping.class, m, start);
        if (g != null) r.put(PathItem.HttpMethod.GET, merge(g.value(), g.path(), ""));
        PostMapping p = findAnn(PostMapping.class, m, start);
        if (p != null) r.put(PathItem.HttpMethod.POST, merge(p.value(), p.path(), ""));
        PutMapping u = findAnn(PutMapping.class, m, start);
        if (u != null) r.put(PathItem.HttpMethod.PUT, merge(u.value(), u.path(), ""));
        DeleteMapping d = findAnn(DeleteMapping.class, m, start);
        if (d != null) r.put(PathItem.HttpMethod.DELETE, merge(d.value(), d.path(), ""));
        PatchMapping p2 = findAnn(PatchMapping.class, m, start);
        if (p2 != null) r.put(PathItem.HttpMethod.PATCH, merge(p2.value(), p2.path(), ""));
        RequestMapping rm = findAnn(RequestMapping.class, m, start);
        if (rm != null) {
            RequestMethod[] verbs = rm.method().length == 0 ? new RequestMethod[]{RequestMethod.GET} : rm.method();
            for (RequestMethod verb : verbs) {
                r.put(PathItem.HttpMethod.valueOf(verb.name()), merge(rm.value(), rm.path(), ""));
            }
        }
        return r;
    }

    static int countOps(Class<?> c) { // --list 时统计用
        int n = 0;
        for (Method m : operationMethods(c))
            for (List<String> paths : mappings(m, c).values()) n += paths.size();
        return n;
    }

    /** 空时给 {""} 语义 = 类级路径就是全部 */
    private static List<String> merge(String[] value, String[] pathAlias, String empty) {
        if (value.length == 0 && pathAlias.length == 0) return Collections.singletonList(empty);
        List<String> out = new ArrayList<String>();
        for (String s : value) if (!out.contains(s)) out.add(s);
        for (String s : pathAlias) if (!out.contains(s)) out.add(s);
        return out;
    }

    /* ---------------- 参数 ---------------- */

    private void readParams(Method m, Class<?> start, Operation op) {
        for (java.lang.reflect.Parameter p : m.getParameters()) {
            if (p.getAnnotation(Hidden.class) != null) continue;
            io.swagger.v3.oas.annotations.Parameter pAnn = p.getAnnotation(io.swagger.v3.oas.annotations.Parameter.class);
            PathVariable v = p.getAnnotation(PathVariable.class);
            RequestParam q = p.getAnnotation(RequestParam.class);
            RequestHeader h = p.getAnnotation(RequestHeader.class);
            CookieValue ck = p.getAnnotation(CookieValue.class);
            org.springframework.web.bind.annotation.RequestBody b =
                    p.getAnnotation(org.springframework.web.bind.annotation.RequestBody.class);

            if (b != null) continue; // readBody 处理
            if (v != null) {
                op.addParametersItem(param("path", name(v.value(), v.name(), p), pAnn, true, simple(p.getParameterizedType())));
            } else if (h != null) { // POC 缺口 2
                op.addParametersItem(param("header", name(h.value(), h.name(), p), pAnn, h.required(), simple(p.getParameterizedType())));
            } else if (ck != null) {
                op.addParametersItem(param("cookie", name(ck.value(), ck.name(), p), pAnn, ck.required(), simple(p.getParameterizedType())));
            } else if (q != null) {
                boolean required = pAnn != null ? pAnn.required() : q.required();
                op.addParametersItem(param("query", name(q.value(), q.name(), p), pAnn, required, simple(p.getParameterizedType())));
            } else if (pAnn != null && (pAnn.in() == ParameterIn.QUERY || pAnn.in() == ParameterIn.HEADER
                    || pAnn.in() == ParameterIn.PATH || pAnn.in() == ParameterIn.COOKIE)) {
                op.addParametersItem(param(pAnn.in().toString().toLowerCase(java.util.Locale.ENGLISH), name(null, null, p), pAnn, pAnn.required(), simple(p.getParameterizedType())));
            } else if (pAnn == null && !isSimple(p.getParameterizedType())) {
                // POJO 查询对象（@ModelAttribute 同路径）展开成 query 参数
                expandBean(p.getType(), op);
            }
            // 无注解的简单类型参数：POC 同为跳过（依赖 -parameters，见 tec-ready Risks）
        }
    }

    private void expandBean(Class<?> bean, Operation op) {
        for (Field f : allFields(bean)) {
            if (Modifier.isStatic(f.getModifiers()) || Modifier.isTransient(f.getModifiers())) continue;
            if (f.getName().startsWith("$")) continue;
            io.swagger.v3.oas.annotations.media.Schema s =
                    f.getAnnotation(io.swagger.v3.oas.annotations.media.Schema.class);
            if (s != null && s.hidden()) continue;
            Parameter pm = new Parameter().name(f.getName()).in("query").required(false).schema(simple(f.getGenericType()));
            if (s != null) {
                if (!s.description().isEmpty()) pm.setDescription(s.description());
                if (!s.example().isEmpty()) pm.setExample(s.example());
            }
            op.addParametersItem(pm);
        }
    }

    private static Parameter param(String in, String n, io.swagger.v3.oas.annotations.Parameter ann,
                                   boolean required, Schema<?> schema) {
        Parameter p = new Parameter().name(n).in(in).required(required).schema(schema);
        if (ann != null && !ann.description().isEmpty()) p.setDescription(ann.description());
        return p;
    }

    private String name(String value, String name, java.lang.reflect.Parameter p) {
        if (value != null && !value.isEmpty()) return value;
        if (name != null && !name.isEmpty()) return name;
        if (p.getName().matches("arg\\d+")) unnamed++; // -parameters 未开启的信号
        return p.getName();
    }

    private static List<Field> allFields(Class<?> c) {
        List<Field> r = new ArrayList<Field>();
        while (c != null && c != Object.class) {
            r.addAll(Arrays.asList(c.getDeclaredFields()));
            c = c.getSuperclass();
        }
        return r;
    }

    /* ---------------- body / response ---------------- */

    private void readBody(Method m, Operation op) {
        for (java.lang.reflect.Parameter p : m.getParameters()) {
            if (p.getAnnotation(org.springframework.web.bind.annotation.RequestBody.class) == null) continue;
            Schema<?> s = ref(p.getParameterizedType());
            if (s != null) {
                // shortcut: 仅 application/json，multipart/form-data 上传接口需要时再扩
                op.setRequestBody(new io.swagger.v3.oas.models.parameters.RequestBody().required(true)
                        .content(new Content().addMediaType("application/json", new MediaType().schema(s))));
            }
        }
    }

    private void readResponse(Method m, Operation op) {
        Type rt = unwrap(m.getGenericReturnType());
        ApiResponse resp = new ApiResponse().description("OK");
        if (rt != void.class && rt != Void.class) {
            Schema<?> s = ref(rt);
            if (s != null) resp.setContent(new Content().addMediaType("*/*", new MediaType().schema(s)));
        }
        op.setResponses(new ApiResponses().addApiResponse("200", resp));
    }

    /** POC 缺口 4：ResponseEntity<T> 解包取 T */
    private static Type unwrap(Type t) {
        if (t instanceof ParameterizedType) {
            ParameterizedType pt = (ParameterizedType) t;
            if (pt.getRawType() == org.springframework.http.ResponseEntity.class && pt.getActualTypeArguments().length > 0) {
                return pt.getActualTypeArguments()[0];
            }
        }
        return t;
    }

    /* ---------------- model / 简单类型 ---------------- */

    /** swagger-core 反解泛型 + @Schema，注册进 components 并返回 $ref */
    private Schema<?> ref(Type type) {
        Map<String, Schema> schemas = converters.readAll(type);
        if (schemas == null || schemas.isEmpty()) return simple(type);
        for (Map.Entry<String, Schema> e : schemas.entrySet()) components.addSchemas(e.getKey(), e.getValue());
        return new Schema<Object>().$ref("#/components/schemas/" + schemas.keySet().iterator().next());
    }

    private static Schema<?> simple(Type t) {
        if (t == String.class || t == char.class || t == Character.class) return new Schema<String>().type("string");
        if (t == int.class || t == Integer.class) return new Schema<Integer>().type("integer").format("int32");
        if (t == long.class || t == Long.class) return new Schema<Long>().type("integer").format("int64");
        if (t == boolean.class || t == Boolean.class) return new Schema<Boolean>().type("boolean");
        if (t == double.class || t == Double.class || t == float.class || t == Float.class) return new Schema<Double>().type("number");
        if (t instanceof Class && ((Class<?>) t).isArray())
            return new Schema<Object>().type("array").items(simple(((Class<?>) t).getComponentType()));
        return new Schema<Object>().type("object");
    }

    private static boolean isSimple(Type t) {
        if (!(t instanceof Class)) return false;
        Class<?> c = (Class<?>) t;
        return c.isPrimitive() || c == String.class || Number.class.isAssignableFrom(c)
                || c == Boolean.class || c == Character.class
                || servletByPackage(c); // servlet-api 不进 CLI 依赖，按包名判断
    }

    private static boolean servletByPackage(Class<?> c) {
        return c.getName().startsWith("javax.servlet.");
    }

    static String join(String base, String sub) {
        String path = (base == null ? "" : base) + (sub == null ? "" : sub);
        if (path.isEmpty()) path = "/";
        return path.startsWith("/") ? path : "/" + path;
    }
}
