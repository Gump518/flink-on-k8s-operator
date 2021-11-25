#!/bin/bash

# Downloads the most recently released kustomize binary
# to your current working directory.

curl -s https://api.github.com/repos/kubernetes-sigs/kustomize/releases |\
  grep browser_download_url |\
  grep linux_amd64 |\
  cut -d '"' -f 4 |\
  grep /kustomize/v |\
  sort | tail -n 1 |\
  xargs curl -s -O -L