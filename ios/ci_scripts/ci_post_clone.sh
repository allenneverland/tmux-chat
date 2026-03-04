#!/bin/bash
echo "$XCCONFIG" | base64 --decode > "${CI_PRIMARY_REPOSITORY_PATH}/ios/TmuxChat/Config.xcconfig"
