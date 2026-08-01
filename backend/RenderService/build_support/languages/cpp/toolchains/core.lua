includes(path.join(path.directory(os.scriptdir()), "options.lua"))

-- The managed-toolchains implementation lives entirely in import()-modules:
-- shared logic under build_support/core/modules (base, errors, i18n, layout,
-- settings, hosttools, envs, run, download, makerunner) and language-specific
-- logic under build_support/languages/<lang>/modules (for C++: gccsources,
-- hostboot, gcctargets, gccbuild, gccstatus, gccpatches). The description
-- shells (cpp/xmake.lua and the toolchains/*.lua satellites) import those
-- modules directly from their own rule/toolchain/task callbacks; the former
-- runtime-accessor (xos/xpath/xio/xtable/ximport + enter_task_runtime) and
-- old-global-name forwarding layers are gone. options.lua stays the only
-- description-scope bootstrap: option defaults are evaluated before any
-- module can load, so it keeps its own small self-contained helpers.
