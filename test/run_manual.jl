# Manual test driver for JuliaStaticData.jl
# Usage:
#   JULIA_DEPOT_PATH=/home/agent/content/workspace/depot/ \
#   JULIA_LOAD_PATH=/home/agent/content/workspace/env/:@:@stdlib \
#   /home/agent/content/workspace/usr/bin/julia test/run_manual.jl

import Pkg

pkg_path = joinpath(@__DIR__, "..")
test_path = joinpath(@__DIR__)

# Activate the package so JuliaStaticData is loadable
Pkg.activate(pkg_path)

import TestItemRunner

# Filter: run all test items, or set a filter for specific tests
# Examples:
#   test_filter = ti -> true                                          # all tests
#   test_filter = ti -> splitpath(ti.filename)[end] == "test_header.jl"  # header tests only
#   test_filter = ti -> ti.name == "remap dependency build-id roundtrip" # single test
test_filter = ti -> true

TestItemRunner.run_tests(test_path; filter=test_filter, verbose=true)
