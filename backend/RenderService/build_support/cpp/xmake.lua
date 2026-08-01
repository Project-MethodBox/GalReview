-- Compatibility shim: the root xmake.lua (and through it the Test
-- subproject) includes this historical path. The real entry is
-- build_support/xmake.lua; the C++ provider itself now lives under
-- build_support/languages/cpp/ (phase 3 directory split).
includes(path.join(path.directory(os.scriptdir()), "xmake.lua"))
