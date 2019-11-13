#!/usr/bin/env bash

if [ ! -f "params" ]; then
  echo "The \"params\" file doesn't exist, not running anything.."
  exit 1
fi
# shellcheck disable=SC1091
source params

if [ -n "${TOKEN}" ] && [ -n "${TARGET_APP_ID}" ]; then
  # Create updater file from template with the current commit
  sed 's/%%TOKEN%%/'"${TOKEN}"'/; s/%%TARGET_APP_ID%%/'"${TARGET_APP_ID}"'/; s/%%FROM_VOLUME%%/'"${FROM_VOLUME}"'/; s/%%TO_VOLUME%%/'"${TO_VOLUME}"'/' appmigrator_template.sh > appmigrator.sh || (echo "appmigrator templating failed" ; exit 1)
  # shellcheck disable=SC2002
  cat batch | stdbuf -oL xargs -I{} -P 30 /bin/sh -c "grep -a -q '{} : DONE' appmigrator.log || (cat appmigrator.sh | balena ssh {} | sed 's/^/{} : /' | tee -a appmigrator.log)"
else
  echo "Check if required parameters are set in the 'params' file!"
  exit 2
fi
