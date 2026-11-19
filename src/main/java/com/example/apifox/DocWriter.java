package com.example.apifox;

import io.swagger.v3.core.util.Json;
import io.swagger.v3.oas.models.OpenAPI;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.Locale;

final class DocWriter {

    private DocWriter() {}

    static void write(OpenAPI api, File out) throws Exception {
        String json = Json.mapper().writerWithDefaultPrettyPrinter().writeValueAsString(api);
        if (out == null) {
            System.out.println(json);
        } else {
            Files.write(out.toPath(), json.getBytes(StandardCharsets.UTF_8));
        }
    }

    static void stats(int controllers, int paths, int ops, int schemas, int unnamed, long loadMs, long start) {
        System.err.printf(Locale.ROOT,
                "controllers=%d paths=%d ops=%d schemas=%d unnamed=%d load=%dms elapsed=%.1fs%n",
                controllers, paths, ops, schemas, unnamed, loadMs, (System.currentTimeMillis() - start) / 1000.0);
    }
}
