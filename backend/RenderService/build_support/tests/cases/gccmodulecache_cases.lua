-- Fixture regression for the path-normalization core in gccmodulecache.lua.
-- The production wrapper touches xmake's live localcache; these cases only
-- provide ordinary tables and sandbox paths.

local gccmodulecache = import("gccmodulecache",
    {rootdir = path.join(os.scriptdir(), "..", "..", "languages", "cpp", "modules"), anonymous = true})

function run(t)
    t.case("gccmodulecache: -P relative generated paths become build-root absolute paths", function ()
        local root = t.tmpdir("gccmodulecache-relative")
        local projectdir = path.join(root, "WhiteHopeEngine.Test")
        local builddir = path.join(root, "build")
        local sourcefile = path.join(root, "WhiteHopeEngine", "cpp", "WhiteHopeEngine.cpp")
        local cmifile = path.join(builddir, ".gens", "WhiteHopeEngine", "windows", "x64", "debug", "WhiteHopeEngine.gcm")
        os.mkdir(projectdir)
        t.write(sourcefile, "export module WhiteHopeEngine;\n")
        t.write(cmifile, "fixture")

        local module = {
            bmifile = [[..\build\.gens\WhiteHopeEngine\windows\x64\debug\WhiteHopeEngine.gcm]],
            sourcefile = [[..\WhiteHopeEngine\cpp\WhiteHopeEngine.cpp]],
            objectfile = [[..\build\.objs\WhiteHopeEngine\windows\x64\debug\WhiteHopeEngine.cpp.obj]]
        }
        local entry = {
            ["c++.modules"] = {main = module},
            module_mapper = {WhiteHopeEngine = module},
            ["c++.build.sourcebatch"] = {
                objectfiles = {[[..\build\.objs\WhiteHopeEngine\windows\x64\debug\WhiteHopeEngine.cpp.obj]]},
                dependfiles = {[[..\build\.deps\WhiteHopeEngine\windows\x64\debug\WhiteHopeEngine.cpp.obj.d]]},
                sourcefiles = {[[..\WhiteHopeEngine\cpp\WhiteHopeEngine.cpp]]}
            }
        }

        local changed = gccmodulecache.normalize_entry(entry, {
            projectdir = projectdir,
            workingdir = root,
            builddir = builddir
        })
        t.assert_true(changed >= 4, "all generated output path categories should be normalized")
        t.assert_eq(module.bmifile, path.absolute(cmifile), "CMI path uses the configured build root")
        t.assert_eq(module.sourcefile, [[..\WhiteHopeEngine\cpp\WhiteHopeEngine.cpp]],
            "source identity remains relative for xmake's mapper keys")
        t.assert_true(path.is_absolute(module.objectfile), "object path becomes absolute")
    end)

    t.case("gccmodulecache: paths already absolute are a stable no-op", function ()
        local root = t.tmpdir("gccmodulecache-absolute")
        local entry = {
            ["c++.modules"] = {
                main = {
                    bmifile = path.join(root, "build", ".gens", "main.gcm"),
                    sourcefile = path.join(root, "src", "main.cpp")
                }
            }
        }
        local changed = gccmodulecache.normalize_entry(entry, {
            projectdir = root,
            workingdir = root,
            builddir = path.join(root, "build")
        })
        t.assert_eq(changed, 0, "absolute cache paths must remain untouched")
    end)

    t.case("gccmodulecache: stale mapper from another build root is rejected", function ()
        local root = t.tmpdir("gccmodulecache-mapper-detection")
        local projectdir = path.join(root, "WhiteHopeEngine.Test")
        local builddir = path.join(root, "build")
        local stale_builddir = path.join(projectdir, "build")
        local stale = table.concat({
            "root " .. path.unix(projectdir),
            "WhiteHopeEngine " .. path.unix(path.join(stale_builddir, ".gens", "WhiteHopeEngine.gcm")),
            ""
        }, "\n")
        local current = table.concat({
            "root " .. path.unix(projectdir),
            "WhiteHopeEngine " .. path.unix(path.join(builddir, ".gens", "WhiteHopeEngine.gcm")),
            ""
        }, "\n")

        t.assert_true(gccmodulecache.mapper_requires_refresh(stale, {
            projectdir = projectdir,
            builddir = builddir
        }), "mapper resolving generated CMIs under an old build root must be refreshed")
        t.assert_true(not gccmodulecache.mapper_requires_refresh(current, {
            projectdir = projectdir,
            builddir = builddir
        }), "mapper using the configured build root remains valid")
    end)

    t.case("gccmodulecache: refresh removes only stale mappers owned by this project", function ()
        local root = t.tmpdir("gccmodulecache-mapper-refresh")
        local projectdir = path.join(root, "WhiteHopeEngine.Test")
        local builddir = path.join(root, "build")
        local tempdir = path.join(root, "temp")
        local stale_mapper = path.join(tempdir, "stale", "test.cpp.mapper.txt")
        local current_mapper = path.join(tempdir, "current", "test.cpp.mapper.txt")
        local foreign_mapper = path.join(tempdir, "foreign", "test.cpp.mapper.txt")

        t.write(stale_mapper, table.concat({
            "root " .. path.unix(projectdir),
            "WhiteHopeEngine " .. path.unix(path.join(projectdir, "build", ".gens", "WhiteHopeEngine.gcm")),
            ""
        }, "\n"))
        t.write(current_mapper, table.concat({
            "root " .. path.unix(projectdir),
            "WhiteHopeEngine " .. path.unix(path.join(builddir, ".gens", "WhiteHopeEngine.gcm")),
            ""
        }, "\n"))
        t.write(foreign_mapper, table.concat({
            "root " .. path.unix(path.join(root, "OtherProject")),
            "Other " .. path.unix(path.join(root, "OtherProject", "build", ".gens", "Other.gcm")),
            ""
        }, "\n"))

        local removed = gccmodulecache.refresh_stale_mapper_files({
            projectdir = projectdir,
            builddir = builddir,
            tempdir = tempdir
        })
        t.assert_eq(removed, 1, "exactly one stale mapper is removed")
        t.assert_true(not os.isfile(stale_mapper), "stale mapper is removed")
        t.assert_true(os.isfile(current_mapper), "current mapper is preserved")
        t.assert_true(os.isfile(foreign_mapper), "another project's mapper is preserved")
    end)

    t.case("gccmodulecache: refresh_stale_mapper_files is safe to call twice for the same build root", function ()
        local root = t.tmpdir("gccmodulecache-mapper-refresh-repeat")
        local projectdir = path.join(root, "WhiteHopeEngine.Test")
        local builddir = path.join(root, "build")
        local tempdir = path.join(root, "temp")
        local context = {projectdir = projectdir, builddir = builddir, tempdir = tempdir}

        local removed1, failed1 = gccmodulecache.refresh_stale_mapper_files(context)
        t.assert_eq(removed1, 0, "nothing to remove on the first call in an empty tempdir")
        t.assert_true(failed1 ~= nil, "first call must not return nil for failed_mappers")
        t.assert_eq(#failed1, 0, "first call returns an empty failed list")

        -- second call for the identical (projectdir, builddir, tempdir) key hits the
        -- memoized "already prepared" fast path -- this used to return only one value,
        -- leaving failed_mappers nil and crashing any caller that does #failed_mappers
        local removed2, failed2 = gccmodulecache.refresh_stale_mapper_files(context)
        t.assert_eq(removed2, 0, "second call for the same build root is a memoized no-op")
        t.assert_true(failed2 ~= nil, "second call must not return nil for failed_mappers")
        t.assert_eq(#failed2, 0, "second call returns an empty failed list, not nil")
    end)

    t.case("gccmodulecache: compiler frontend change invalidates cache and generated CMIs", function ()
        local root = t.tmpdir("gccmodulecache-compiler-change")
        local prefix = path.join(root, "toolchain")
        local compiler = path.join(prefix, "bin", "g++")
        local frontend = path.join(prefix, "libexec", "gcc", "fixture", "17.0.0", "cc1plus")
        local std_module = path.join(prefix, "include", "c++", "17.0.0", "bits", "std.cc")
        t.write(compiler, "stable compiler driver")
        t.write(frontend, "old compiler frontend")
        t.write(std_module, "export module std;\n")

        local cache_data = {}
        local cache = {
            clear_count = 0,
            save_count = 0,
            clear = function (self)
                self.clear_count = self.clear_count + 1
                cache_data = {}
            end,
            save = function (self)
                self.save_count = self.save_count + 1
            end,
            data = function ()
                return cache_data
            end
        }
        local target = {
            tool = function () return compiler, "gcc" end,
            plat = function () return "windows" end,
            arch = function () return "x64" end,
            fullname = function () return "fixture" end
        }

        local baseline_cachedir = path.join(root, "baseline-cache")
        gccmodulecache.prepare(target, {
            cache = cache,
            cachedir = baseline_cachedir,
            projectdir = root,
            workingdir = root,
            builddir = path.join(root, "baseline-build"),
            tempdir = path.join(root, "baseline-temp")
        })
        t.assert_eq(cache.clear_count, 0, "a fresh cache records its compiler without invalidation")
        local baseline_marker = path.join(baseline_cachedir, "cxxmodules.compiler.windows.x64")
        local baseline_fingerprint = io.readfile(baseline_marker)

        t.write(frontend, "new compiler frontend")
        local builddir = path.join(root, "build")
        local cachedir = path.join(root, "cache")
        local tempdir = path.join(root, "temp")
        local marker = path.join(cachedir, "cxxmodules.compiler.windows.x64")
        local cmidir = path.join(builddir, ".gens", "fixture", "windows", "x64", "debug")
        t.write(marker, baseline_fingerprint)
        t.write(path.join(cmidir, "fixture.gcm"), "old CMI")

        gccmodulecache.prepare(target, {
            cache = cache,
            cachedir = cachedir,
            projectdir = root,
            workingdir = root,
            builddir = builddir,
            tempdir = tempdir
        })

        t.assert_eq(cache.clear_count, 1, "a changed C++ frontend clears the module localcache")
        t.assert_true(cache.save_count >= 1, "the cleared localcache is persisted")
        t.assert_true(not os.isdir(path.join(builddir, ".gens", "fixture", "windows", "x64")),
            "CMIs for the active platform and architecture are removed")
        t.assert_true(io.readfile(marker) ~= "old compiler fingerprint",
            "the compiler fingerprint marker is refreshed")
    end)
end
