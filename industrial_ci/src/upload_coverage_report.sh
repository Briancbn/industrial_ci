#!/bin/bash

# Copyright (c) 2020, Chen Bainian
# Copyright (c) 2018, Mathias Lüdtke
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

# Upload Coverage Report

function upload_coverage_report {
  case "$CODE_COVERAGE" in
    "codecov.io")
      bash <(curl -s https://codecov.io/bash) -Z
      ;;
    "coveralls.io")
      pip install --user --upgrade pip
      pip install --user coveralls
      coveralls --merge=.ici_coverage_report/coverage.json
      ;;
  esac
}

upload_coverage_report
