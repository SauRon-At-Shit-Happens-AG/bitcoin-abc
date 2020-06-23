#!/usr/bin/env bash

export LC_ALL=C.UTF-8

set -euxo pipefail

: "${ABC_BUILD_NAME:=""}"

if [ $# -ge 1 ]; then
  ABC_BUILD_NAME="$1"
  shift
fi

if [ -z "${ABC_BUILD_NAME}" ]; then
  echo "Error: Environment variable ABC_BUILD_NAME must be set"
  exit 1
fi

echo "Running build configuration '${ABC_BUILD_NAME}'..."

TOPLEVEL=$(git rev-parse --show-toplevel)
export TOPLEVEL

setup() {
  # Use separate build dirs to get the most out of ccache and prevent crosstalk
  : "${BUILD_DIR:=${TOPLEVEL}/${ABC_BUILD_NAME}}"
  mkdir -p "${BUILD_DIR}"
  BUILD_DIR=$(cd "${BUILD_DIR}"; pwd)
  export BUILD_DIR

  cd "${BUILD_DIR}"

  # Determine the number of build threads
  THREADS=$(nproc || sysctl -n hw.ncpu)
  export THREADS

  CMAKE_PLATFORMS_DIR="${TOPLEVEL}/cmake/platforms"

  # Base directories for sanitizer related files
  SAN_SUPP_DIR="${TOPLEVEL}/test/sanitizer_suppressions"
  SAN_LOG_DIR="/tmp/sanitizer_logs"

  # Create the log directory if it doesn't exist and clear it
  mkdir -p "${SAN_LOG_DIR}"
  rm -rf "${SAN_LOG_DIR:?}"/*

  # Needed options are set by the build system, add the log path to all runs
  export ASAN_OPTIONS="log_path=${SAN_LOG_DIR}/asan.log"
  export LSAN_OPTIONS="log_path=${SAN_LOG_DIR}/lsan.log"
  export TSAN_OPTIONS="log_path=${SAN_LOG_DIR}/tsan.log"
  export UBSAN_OPTIONS="log_path=${SAN_LOG_DIR}/ubsan.log"

  # Unit test logger parameters
  UNIT_TESTS_JUNIT_LOG_LEVEL=message
}

run_test_bitcoin() {
  # Usage: run_test_bitcoin "Context as string" [arguments...]
  ninja test_bitcoin

  TEST_BITCOIN_JUNIT="junit_results_unit_tests${1:+_${1// /_}}.xml"
  TEST_BITCOIN_SUITE_NAME="Bitcoin ABC unit tests${1:+ $1}"

  # More sanitizer options are needed to run the executable directly
  ASAN_OPTIONS="malloc_context_size=0:${ASAN_OPTIONS}" \
  LSAN_OPTIONS="suppressions=${SAN_SUPP_DIR}/lsan:${LSAN_OPTIONS}" \
  TSAN_OPTIONS="suppressions=${SAN_SUPP_DIR}/tsan:${TSAN_OPTIONS}" \
  UBSAN_OPTIONS="suppressions=${SAN_SUPP_DIR}/ubsan:print_stacktrace=1:halt_on_error=1:${UBSAN_OPTIONS}" \
  ./src/test/test_bitcoin \
    --logger=HRF:JUNIT,${UNIT_TESTS_JUNIT_LOG_LEVEL},${TEST_BITCOIN_JUNIT} \
    -- \
    -testsuitename="${TEST_BITCOIN_SUITE_NAME}" \
    "${@:2}"
}

# Facility to print out sanitizer log outputs to the build log console
print_sanitizers_log() {
  for log in "${SAN_LOG_DIR}"/*.log.*
  do
    if [ -f "${log}" ]; then
      echo "*** Output of ${log} ***"
      cat "${log}"
    fi
  done
}
trap "print_sanitizers_log" ERR

CI_SCRIPTS_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
DEVTOOLS_DIR="${TOPLEVEL}"/contrib/devtools

build_with_cmake() {
  CMAKE_FLAGS="${CMAKE_FLAGS[*]}" "${DEVTOOLS_DIR}"/build_cmake.sh "$@"
}

setup

case "$ABC_BUILD_NAME" in
  build-asan)
    # Build with the address sanitizer, then run unit tests and functional tests.
    CMAKE_FLAGS=(
      "-DCMAKE_CXX_FLAGS=-DARENA_DEBUG"
      "-DCMAKE_BUILD_TYPE=Debug"
      # ASAN does not support assembly code: https://github.com/google/sanitizers/issues/192
      # This will trigger a segfault if the SSE4 implementation is selected for SHA256.
      # Disabling the assembly works around the issue.
      "-DCRYPTO_USE_ASM=OFF"
      "-DENABLE_SANITIZERS=address"
    )
   build_with_cmake --Werror --clang

    run_test_bitcoin "with address sanitizer"

    # Libs and utils tests
    ninja \
      check-bitcoin-qt \
      check-bitcoin-seeder \
      check-bitcoin-util \

    ninja check-functional
    ;;

  build-ubsan)
    # Build with the undefined sanitizer, then run unit tests and functional tests.
    CMAKE_FLAGS=(
      "-DCMAKE_BUILD_TYPE=Debug"
      "-DENABLE_SANITIZERS=undefined"
    )
    build_with_cmake --Werror --clang

    run_test_bitcoin "with undefined sanitizer"

    # Libs and utils tests
    ninja \
      check-bitcoin-qt \
      check-bitcoin-seeder \
      check-bitcoin-util \

    ninja check-functional
    ;;

  build-tsan)
    # Build with the thread sanitizer, then run unit tests and functional tests.
    CMAKE_FLAGS=(
      "-DENABLE_SANITIZERS=thread"
    )
    build_with_cmake --Werror --clang

    run_test_bitcoin "with thread sanitizer"

    # Libs and utils tests
    ninja \
      check-bitcoin-qt \
      check-bitcoin-seeder \
      check-bitcoin-util \

    ninja check-functional
    ;;

  build-diff)
    # Build, run unit tests and functional tests.
    build_with_cmake --Werror

    # Unit tests
    run_test_bitcoin
    run_test_bitcoin "with next upgrade activated" -phononactivationtime=1575158400

    # Libs and tools tests
    # The leveldb tests need to run alone or they will sometimes fail with
    # garbage output, see:
    # https://build.bitcoinabc.org/viewLog.html?buildId=29713&guest=1
    ninja check-leveldb
    ninja \
      check-bitcoin-qt \
      check-bitcoin-seeder \
      check-bitcoin-util \
      check-devtools \
      check-rpcauth \
      check-secp256k1 \
      check-univalue \

    # Functional tests
    ninja check-functional
    ninja check-functional-upgrade-activated
    ;;

  build-master)
    # Build, run unit tests and extended functional tests.
    build_with_cmake --Werror

    # Unit tests
    run_test_bitcoin
    run_test_bitcoin "with next upgrade activated" -phononactivationtime=1575158400

    # Libs and tools tests
    # The leveldb tests need to run alone or they will sometimes fail with
    # garbage output, see:
    # https://build.bitcoinabc.org/viewLog.html?buildId=29713&guest=1
    ninja check-leveldb
    ninja \
      check-bitcoin-qt \
      check-bitcoin-seeder \
      check-bitcoin-util \
      check-devtools \
      check-rpcauth \
      check-secp256k1 \
      check-univalue \

    # Functional tests
    ninja check-functional-extended
    ninja check-functional-upgrade-activated-extended
    ;;

  build-secp256k1)
    # Enable all the features but endomorphism.
    CMAKE_FLAGS=(
      "-DSECP256K1_ENABLE_MODULE_ECDH=ON"
      "-DSECP256K1_ENABLE_MODULE_MULTISET=ON"
    )
    build_with_cmake --Werror secp256k1

    ninja check-secp256k1

    # Repeat with endomorphism.
    CMAKE_FLAGS+=(
      "-DSECP256K1_ENABLE_ENDOMORPHISM=ON"
    )
    build_with_cmake --Werror secp256k1

    ninja check-secp256k1

    # Check JNI bindings. Note that Jemalloc needs to be disabled:
    # https://github.com/jemalloc/jemalloc/issues/247
    CMAKE_FLAGS=(
      "-DSECP256K1_ENABLE_MODULE_ECDH=ON"
      "-DSECP256K1_ENABLE_JNI=ON"
      "-DUSE_JEMALLOC=OFF"
    )
    build_with_cmake --Werror secp256k1

    ninja check-secp256k1-java
    ;;

  build-without-cli)
    # Build without bitcoin-cli
    CMAKE_FLAGS=(
      "-DBUILD_BITCOIN_CLI=OFF"
    )
    build_with_cmake --Werror

    ninja check-functional
    ;;

  build-without-wallet)
    # Build without wallet and run the unit tests.
    CMAKE_FLAGS=(
      "-DBUILD_BITCOIN_WALLET=OFF"
    )
    build_with_cmake --Werror

    ninja check-bitcoin-qt
    ninja check-functional

    run_test_bitcoin "without wallet"
    ;;

  build-without-zmq)
    # Build without Zeromq and run the unit tests.
    CMAKE_FLAGS=(
      "-DBUILD_BITCOIN_ZMQ=OFF"
    )
    build_with_cmake --Werror

    ninja check-bitcoin-qt
    ninja check-functional

    run_test_bitcoin "without zmq"
    ;;

  build-ibd)
    build_with_cmake

    "${CI_SCRIPTS_DIR}"/ibd.sh -disablewallet -debug=net
    ;;

  build-ibd-no-assumevalid-checkpoint)
    build_with_cmake

    "${CI_SCRIPTS_DIR}"/ibd.sh -disablewallet -assumevalid=0 -checkpoints=0 -debug=net
    ;;

  build-clang-10)
    # Use clang-10 for this build instead of the default clang-8.
    # This allow for checking that no warning is introduced for newer versions
    # of the compiler
    CMAKE_FLAGS=(
      "-DCMAKE_C_COMPILER=clang-10"
      "-DCMAKE_CXX_COMPILER=clang++-10"
    )
    build_with_cmake --Werror

    ninja \
      test_bitcoin \
      test_bitcoin-qt \
      test_bitcoin-seeder \
      secp256k1-tests \
      secp256k1-exhaustive_tests

    # TODO do the same with the latest GCC
    ;;

  build-autotools)
    # Ensure that the build using autotools is not broken
    "${DEVTOOLS_DIR}"/build_autotools.sh check
    ;;

  build-bench)
    # Build and run the benchmarks.
    CMAKE_FLAGS=(
      "-DBUILD_BITCOIN_WALLET=ON"
      "-DSECP256K1_ENABLE_MODULE_ECDH=ON"
      "-DSECP256K1_ENABLE_MODULE_MULTISET=ON"
    )
    build_with_cmake --Werror bitcoin-bench

    ./src/bench/bitcoin-bench -printer=junit > junit_results_bench.xml

    ninja bench-secp256k1
    ;;

  build-make-generator)
    # Ensure that the build using cmake and the "Unix Makefiles" generator is
    # not broken.
    cd ${BUILD_DIR}
    git clean -xffd
    cmake -G "Unix Makefiles" ..
    make -j "${THREADS}" all check
    ;;

  build-coverage)
    CMAKE_FLAGS=(
      "-DENABLE_COVERAGE=ON"
      "-DENABLE_BRANCH_COVERAGE=ON"
    )
    build_with_cmake --gcc coverage-check-extended

    # Publish the coverage report in a format that Teamcity understands
    pushd check-extended.coverage
    # Run from the coverage directory to prevent tar from creating a top level
    # folder in the generated archive.
    tar -czf ../coverage.tar.gz -- *
    popd
  ;;

  build-clang-tidy)
    CMAKE_FLAGS=(
      "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON"
    )
    build_with_cmake --clang

    # Set the default for debian but allow the user to override, as the name is
    # not standard across distributions (and it's not always in the PATH).
    : "${CLANG_TIDY_DIFF_SCRIPT:=clang-tidy-diff-8.py}"
    CLANG_TIDY_WARNING_FILE="${BUILD_DIR}/clang-tidy-warnings.txt"

    pushd "${TOPLEVEL}"
    git diff -U0 HEAD^ | "${CLANG_TIDY_DIFF_SCRIPT}" \
      -clang-tidy-binary "$(command -v clang-tidy-8)" \
      -path "${BUILD_DIR}/compile_commands.json" \
      -p1 > "${CLANG_TIDY_WARNING_FILE}"
    if [ $(wc -l < "${CLANG_TIDY_WARNING_FILE}") -gt 1 ]; then
      echo "clang-tidy found issues !"
      cat "${CLANG_TIDY_WARNING_FILE}"
      exit 1
    fi
    popd
  ;;

  build-win64)
    "${DEVTOOLS_DIR}"/build_depends.sh
    CMAKE_FLAGS=(
      "-DCMAKE_TOOLCHAIN_FILE=${CMAKE_PLATFORMS_DIR}/Win64.cmake"
      "-DBUILD_BITCOIN_SEEDER=OFF"
      "-DCPACK_STRIP_FILES=ON"
    )
    build_with_cmake

    # Build all the targets that are not built as part of the default target
    ninja test_bitcoin test_bitcoin-qt

    ninja package

    # Running the tests with wine and jemalloc is causing deadlocks, so disable
    # jemalloc prior running the tests.
    # FIXME figure out what is causing the deadlock. Example output:
    #   01fe:err:ntdll:RtlpWaitForCriticalSection section 0x39e081b0 "?" wait
    #   timed out in thread 01fe, blocked by 01cd, retrying (60 sec)
    CMAKE_FLAGS+=(
      "-DUSE_JEMALLOC=OFF"
    )
    build_with_cmake test_bitcoin

    # Run the tests. Not all will run with wine, so exclude them
    find src -name "libbitcoinconsensus*.dll" -exec cp {} src/test/ \;
    wine ./src/test/test_bitcoin.exe --run_test=\!radix_tests,rcu_tests
    ;;

  build-osx)
    export PYTHONPATH="${TOPLEVEL}/depends/x86_64-apple-darwin16/native/lib/python3/dist-packages:${PYTHONPATH:-}"

    "${DEVTOOLS_DIR}"/build_depends.sh
    CMAKE_FLAGS=(
      "-DCMAKE_TOOLCHAIN_FILE=${CMAKE_PLATFORMS_DIR}/OSX.cmake"
    )
    build_with_cmake

    # Build all the targets that are not built as part of the default target
    ninja test_bitcoin test_bitcoin-qt test_bitcoin-seeder

    ninja osx-dmg
    ;;

  build-linux-arm)
    "${DEVTOOLS_DIR}"/build_depends.sh
    CMAKE_FLAGS=(
      "-DCMAKE_TOOLCHAIN_FILE=${CMAKE_PLATFORMS_DIR}/LinuxARM.cmake"
      # This will prepend our executable commands with the given emulator call
      "-DCMAKE_CROSSCOMPILING_EMULATOR=$(command -v qemu-arm-static)"
      # The ZMQ functional test will fail with qemu (due to a qemu limitation),
      # so disable it to avoid the failure.
      # Extracted from stderr:
      #   Unknown host QEMU_IFLA type: 50
      #   Unknown host QEMU_IFLA type: 51
      #   Unknown QEMU_IFLA_BRPORT type 33
      "-DBUILD_BITCOIN_ZMQ=OFF"
      # This is an horrible hack to workaround a qemu bug:
      # https://bugs.launchpad.net/qemu/+bug/1748612
      # Qemu emits a message for unsupported features called by the guest.
      # Because the output filtering is not working at all, it causes the
      # qemu stderr to end up in the node stderr and fail the functional
      # tests.
      # Disabling the unsupported feature (here bypassing the config
      # detection) fixes the issue.
      # FIXME: get rid of the hack, either by using a better qemu version
      # or by filtering stderr at the framework level.
      "-DHAVE_DECL_GETIFADDRS=OFF"
    )
    build_with_cmake

    # Let qemu know where to find the system libraries
    export QEMU_LD_PREFIX=/usr/arm-linux-gnueabihf

    # Unit tests
    ninja check
    ninja check-secp256k1

    # Functional tests
    ninja check-functional
    ;;

  build-linux-aarch64)
    "${DEVTOOLS_DIR}"/build_depends.sh
    CMAKE_FLAGS=(
      "-DCMAKE_TOOLCHAIN_FILE=${CMAKE_PLATFORMS_DIR}/LinuxAArch64.cmake"
      # This will prepend our executable commands with the given emulator call
      "-DCMAKE_CROSSCOMPILING_EMULATOR=$(command -v qemu-aarch64-static)"
      # The ZMQ functional test will fail with qemu (due to a qemu limitation),
      # so disable it to avoid the failure.
      # Extracted from stderr:
      #   Unknown host QEMU_IFLA type: 50
      #   Unknown host QEMU_IFLA type: 51
      #   Unknown QEMU_IFLA_BRPORT type 33
      "-DBUILD_BITCOIN_ZMQ=OFF"
      # This is an horrible hack to workaround a qemu bug:
      # https://bugs.launchpad.net/qemu/+bug/1748612
      # Qemu emits a message for unsupported features called by the guest.
      # Because the output filtering is not working at all, it causes the
      # qemu stderr to end up in the node stderr and fail the functional
      # tests.
      # Disabling the unsupported feature (here bypassing the config
      # detection) fixes the issue.
      # FIXME: get rid of the hack, either by using a better qemu version
      # or by filtering stderr at the framework level.
      "-DHAVE_DECL_GETIFADDRS=OFF"
    )
    build_with_cmake

    # Let qemu know where to find the system libraries
    export QEMU_LD_PREFIX=/usr/aarch64-linux-gnu

    # Unit tests
    ninja check
    ninja check-secp256k1

    # Functional tests
    ninja check-functional
    ;;

  build-linux64)
    "${DEVTOOLS_DIR}"/build_depends.sh

    # Build, run unit tests and functional tests.
    CMAKE_FLAGS=(
      "-DCMAKE_TOOLCHAIN_FILE=${CMAKE_PLATFORMS_DIR}/Linux64.cmake"
      "-DENABLE_PROPERTY_BASED_TESTS=ON"
    )
    build_with_cmake

    # Unit tests
    run_test_bitcoin "for Linux 64 bits"

    ninja \
      check-bitcoin-qt \
      check-bitcoin-seeder \
      check-bitcoin-util \
      check-secp256k1

    # Functional tests
    ninja check-functional
    ;;

  check-seeds)
    build_with_cmake bitcoind bitcoin-cli

    # Run on different ports to avoid a race where the rpc port used in the
    # first run may not be closed in time for the second to start.
    SEEDS_DIR="${TOPLEVEL}"/contrib/seeds
    RPC_PORT=18832 "${SEEDS_DIR}"/check-seeds.sh main 80
    RPC_PORT=18833 "${SEEDS_DIR}"/check-seeds.sh test 70
    ;;

  *)
    echo "Error: Invalid build name '${ABC_BUILD_NAME}'"
    exit 2
    ;;
esac
