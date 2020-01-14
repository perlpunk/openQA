#!/bin/bash

#for i in `tail -n +2 single-test-suites.csv | cut -d, -f1`; do
#    echo $i
#    ./script/client \
#      --host https://openqa.opensuse.org $APIARGS \
#      --json-output \
#      test_suites/$i get >data/testsuites/$i.json
#done

for i in `tail -n +2 single-test-suites.csv | cut -d, -f 4 | sort -u`; do
    echo $i
    ./script/client \
      --host https://openqa.opensuse.org $APIARGS \
      job_templates_scheduling/$i get | jq --raw-output . >data/jobtemplates/$i.yaml

done
