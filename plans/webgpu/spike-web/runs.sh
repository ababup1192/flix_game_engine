#!/bin/bash
cd "$(dirname "$0")"
for i in 1 2 3; do ./run-chrome.sh http://127.0.0.1:8781/index.html sink/post_result.json --enable-unsafe-webgpu; cp sink/post_result.json sink/run$i.json; done
echo ALLDONE
