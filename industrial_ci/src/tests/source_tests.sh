#!/bin/bash

# Copyright (c) 2015, Isaac I. Y. Saito
# Copyright (c) 2019, Mathias Lüdtke
# All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
## Greatly inspired by JSK travis https://github.com/jsk-ros-pkg/jsk_travis

# source_tests.sh script runs integration tests for the target ROS packages.
# It is dependent on environment variables that need to be exported in advance
# (As of version 0.4.4 most of them are defined in env.sh).

function install_catkin_lint {
    ici_install_pkgs_for_command catkin_lint "${PYTHON_VERSION_NAME}-catkin-lint"
}

function run_clang_tidy {
    local regex="$1/.*"
    local -n _run_clang_tidy_warnings=$2
    local -n _run_clang_tidy_errors=$3
    local db=$4
    shift 4

    mapfile -t files < <(grep -oP "(?<=\"file\": \")($regex)(?=\")" "$db")
    if [ "${#files[@]}" -eq 0 ]; then
        return 0
    fi

    local build; build="$(dirname "$db")"
    local name; name="$(basename "$build")"

    local max_jobs="${CLANG_TIDY_JOBS:-$(nproc)}"
    if ! [ "$max_jobs" -ge 1 ]; then
        ici_error "CLANG_TIDY_JOBS=$CLANG_TIDY_JOBS is invalid."
    fi

    rm -rf "$db".{command,warn,error}
    cat > "$db.command" << EOF
#!/bin/bash
fixes=\$(mktemp)
clang-tidy "-export-fixes=\$fixes" "-header-filter=$regex" "-p=$build" "\$@" || { touch "$db.error"; echo "Errored for '\$*'"; }
if [ -s "\$fixes" ]; then touch "$db.warn"; fi
rm -rf "\$fixes"
EOF
    chmod +x "$db.command"

    ici_time_start "clang_tidy_check_$name"
    echo "run clang-tidy for ${#files[@]} file(s) in $max_jobs process(es)."

    printf "%s\0" "${files[@]}" | xargs --null -P "$max_jobs" "$db.command" "$@"

    if [ -f "$db.error" ]; then
       _run_clang_tidy_errors+=("$name")
       ici_time_end "${ANSI_RED}"
    elif [ -f "$db.warn" ]; then
        _run_clang_tidy_warnings+=("$name")
        ici_time_end "${ANSI_YELLOW}"
    else
        ici_time_end
    fi
}

function run_clang_tidy_check {
    local target_ws=$1
    local -a errors
    local -a warnings
    local -a clang_tidy_args
    ici_parse_env_array clang_tidy_args CLANG_TIDY_ARGS

    ici_run "install_clang_tidy" ici_install_pkgs_for_command clang-tidy clang-tidy "$(apt-cache depends --recurse --important clang  | grep "^libclang-common-.*")"

    while read -r db; do
        run_clang_tidy "$target_ws/src" warnings errors "$db" "${clang_tidy_args[@]}"
    done < <(find "$target_ws/build" -name compile_commands.json)

    if [ "${#warnings[@]}" -gt "0" ]; then
        ici_warn "Clang tidy warning(s) in: ${warnings[*]}"
        if [ "$CLANG_TIDY" == "pedantic" ]; then
            errors=( "${warnings[@]}" "${errors[@]}" )
        fi
    fi

    if [ "${#errors[@]}" -gt "0" ]; then
        ici_error "Clang tidy check(s) failed: ${errors[*]}"
    fi
}

function ici_combine_cpp_reports {
  ici_install_pkgs_for_command lcov lcov
  # Capture initial coverage info
  lcov --capture --initial \
       --directory build \
       --output-file initial_coverage.info | grep -ve "^Processing"
  # Capture tested coverage info
  lcov --capture \
       --directory build \
       --output-file test_coverage.info | grep -ve "^Processing"
  # Combine two report (exit function  when none of the records are valid)
  lcov --add-tracefile initial_coverage.info \
       --add-tracefile test_coverage.info \
       --output-file coverage.info || return 0 \
    && rm initial_coverage.info test_coverage.info
  # Extract repository files
  lcov --extract coverage.info "$(pwd)/src/$TARGET_REPO_NAME/*" \
       --output-file coverage.info | grep -ve "^Extracting"
  # Filter out test files
  lcov --remove coverage.info "*/test/*" \
       --output-file coverage.info | grep -ve "^removing"
  # Filter out ignored packages
  local -a ignored_pkgs
  ici_parse_env_array ignored_pkgs CODE_COVERAGE_IGNORE_PACKAGES

  for pkg in "${ignored_pkgs[@]}"; do
      lcov --remove coverage.info "$(pwd)/src/$TARGET_REPO_NAME/$pkg/*" \
           --output-file coverage.info | grep -ve "^removing"
  done
  # Some sed magic to remove identifiable absolute path
  sed -i "s~$(pwd)/src/$TARGET_REPO_NAME/~~g" coverage.info
  lcov --list coverage.info
}

function ici_combine_python_reports {
  # Find all .coverage file
  local python_reports
  python_reports=$(find "./build" \
                        -type f \
                        -name ".coverage" \
                        -printf "%p ")
  IFS=" " read -r -a python_reports <<< "$python_reports"
  # Combine coverage files
  if "$PYTHON_VERSION_NAME" -m coverage combine "${python_reports[@]}"; then
    local -a package_omits
    package_omits=$(echo "${CODE_COVERAGE_IGNORE_PACKAGES}" | sed 's/ /,/g' | sed -E "s~([^,]+)~src/${TARGET_REPO_NAME}/\1/*~g")
    # Generate report
    "$PYTHON_VERSION_NAME" -m coverage report --include="src/$TARGET_REPO_NAME/*" --omit="*/test/*,*/setup.py,$package_omits" || return 0
    "$PYTHON_VERSION_NAME" -m coverage xml --include="src/$TARGET_REPO_NAME/*" --omit="*/test/*,*/setup.py,$package_omits"
  fi
}

function ici_collect_coverage_report {
  local target_ws=$1

  # Run combine reports command securely
  # within workspace directory
  ( cd "$target_ws" && \
    ici_combine_cpp_reports && \
    ici_combine_python_reports )

  case "$CODE_COVERAGE" in
    "coveralls.io")
      # Combine cpp and python reports locally and expose coverage.json file for coveralls
      cp "$target_ws"/.coverage "$target_ws/src/$TARGET_REPO_NAME" || echo "No python coverage report"
      ici_setup_git_client
      ici_install_pkgs_for_command pip "${PYTHON_VERSION_NAME}-pip" \
        "${PYTHON_VERSION_NAME}-dev" "${PYTHON_VERSION_NAME}-wheel"
      "${PYTHON_VERSION_NAME}" -m pip install coveralls
      # Use coveragerc file used for coveralls ignore
      printf "[report]\ninclude = \n\t%s/src/%s/*\nomit = \n\t*/test/*\n\t*/setup.py" "$target_ws" "$TARGET_REPO_NAME" \
        > "$target_ws/src/$TARGET_REPO_NAME/.default.coveragerc"
      if [ -f "$target_ws"/coverage.info ]; then
        # Install and run coveralls-lcov within git directory
        cp "$target_ws"/coverage.info "$target_ws/src/$TARGET_REPO_NAME"
        ici_install_pkgs_for_command gem ruby
        gem install coveralls-lcov
        ( cd "$target_ws/src/$TARGET_REPO_NAME" && \
          coveralls-lcov -v -n coverage.info > coverage.c.json && \
          coveralls --merge coverage.c.json \
                    --rcfile .default.coveragerc \
                    --output "$COVERAGE_REPORT_PATH"/coverage.json )
      else
        echo "No cpp covearge report"
        ( cd "$target_ws/src/$TARGET_REPO_NAME" && \
          coveralls --rcfile .default.coveragerc \
                    --output "$COVERAGE_REPORT_PATH"/coverage.json )
      fi
      ;;
    *) # Expose LCOV and Cobertura XML files by default
      cp "$target_ws"/coverage.info "$COVERAGE_REPORT_PATH" || echo "No cpp coverage report"
      cp "$target_ws"/coverage.xml "$COVERAGE_REPORT_PATH" || echo "No python coverage report"
      ;;
  esac
}

function run_source_tests {
    # shellcheck disable=SC1090
    source "${ICI_SRC_PATH}/builders/$BUILDER.sh" || ici_error "Builder '$BUILDER' not supported"

    ici_require_run_in_docker # this script must be run in docker
    upstream_ws=~/upstream_ws
    target_ws=~/target_ws
    downstream_ws=~/downstream_ws

    if [ "$CCACHE_DIR" ]; then
        ici_run "setup_ccache" ici_apt_install ccache
        export PATH="/usr/lib/ccache:$PATH"
    fi

    ici_run "${BUILDER}_setup" ici_quiet builder_setup

    ici_run "setup_rosdep" ici_setup_rosdep

    extend="/opt/ros/$ROS_DISTRO"

    if [ -n "$UPSTREAM_WORKSPACE" ]; then
        ici_with_ws "$upstream_ws" ici_build_workspace "upstream" "$extend" "$upstream_ws"
        extend="$upstream_ws/install"
    fi

    if [ "${CLANG_TIDY:-false}" != false ]; then
        TARGET_CMAKE_ARGS="$TARGET_CMAKE_ARGS -DCMAKE_EXPORT_COMPILE_COMMANDS=ON"
    fi
    if [ -n "$CODE_COVERAGE" ]; then
        ici_run "install_coveragepy" ici_install_pkgs_for_command coverage "$PYTHON_VERSION_NAME-coverage"
        TARGET_CMAKE_ARGS="$TARGET_CMAKE_ARGS -DCMAKE_BUILD_TYPE=Debug -DCMAKE_C_FLAGS='--coverage' -DCMAKE_CXX_FLAGS='--coverage'"
        export CATKIN_TEST_COVERAGE=1
    fi
    ici_with_ws "$target_ws" ici_build_workspace "target" "$extend" "$target_ws"

    if [ "$NOT_TEST_BUILD" != "true" ]; then
        ici_with_ws "$target_ws" ici_test_workspace "target" "$extend" "$target_ws"
    fi

    if [ "$CATKIN_LINT" == "true" ] || [ "$CATKIN_LINT" == "pedantic" ]; then
        ici_run "install_catkin_lint" install_catkin_lint
        local -a catkin_lint_args
        ici_parse_env_array catkin_lint_args CATKIN_LINT_ARGS
        if [ "$CATKIN_LINT" == "pedantic" ]; then
          catkin_lint_args+=(--strict -W2)
        fi
        ici_with_ws "$target_ws" ici_run "catkin_lint" ici_exec_in_workspace "$extend" "$target_ws"  catkin_lint --explain "${catkin_lint_args[@]}" src

    fi
    if [ "${CLANG_TIDY:-false}" != false ]; then
        run_clang_tidy_check "$target_ws"
    fi

    if [ -n "${CODE_COVERAGE}" ]; then
        ici_run "collect_target_coverage_report" ici_collect_coverage_report "$target_ws"
    fi

    extend="$target_ws/install"
    if [ -n "$DOWNSTREAM_WORKSPACE" ]; then
        ici_with_ws "$downstream_ws" ici_build_workspace "downstream" "$extend" "$downstream_ws"
        #extend="$downstream_ws/install"

        if [ "$NOT_TEST_DOWNSTREAM" != "true" ]; then
            ici_with_ws "$downstream_ws" ici_test_workspace "downstream" "$extend" "$downstream_ws"
        fi
    fi
}
