includes("build_support/cpp/xmake.lua")

add_rules("toolchains.auto", "gcc.features", "gcc.modules")
add_rules("mode.debug", "mode.release")

target("GalReview.RenderService")
    set_kind("binary")
    set_languages("clatest", "c++26")
    set_encodings("source:utf-8", "target:utf-8")
    set_warnings("allextra")
    add_files("src/**.cpp", {public = true})
