#!/bin/bash
cd /src/unpub
export UNPUB_PACKAGE_DIR=/data/db/unpub-packages
mongod >mogo_out.file 2>&1 &
dart pub get
dart bin/unpub.dart