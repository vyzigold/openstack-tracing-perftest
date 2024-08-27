# Openstack tracing performance testing

This repository consists of various configs, a script for executing various openstack cli commands to create load on the openstack services API, and a few files with measurement results.

## Executing the tests
- Configure all of the required services. You can find config snippets in osprofiler\_configs/ and otel-autoinstrumentation/ folders.
- Run the trace receiving service. In this case either Jaeger (a command to run Jaeger can be found in the jaeger/ folder) or otel-collector (a command to run otel-collector can be found in the otel-collector/ folder).
- Restart the openstack services. In devstack this could be done by executing `sudo systemctl restart devstack@*`
- Execute `./perf-test.sh --init`. This will run the testing scenario once to ensure the actual measured results aren't polluted by various sideeffects, which would happen only once (like downloading images).
- Execute `./perf-test.sh --cycles <number how many times the scenario should run. Each 'cycle' takes around 150s> --result_file <a file where to save the results>`. Optionally add the `--use_os_profiler` to add `--os-profile SECRET_KEY` to each executed openstack command.

## Current results of testing
The results contained in the repository were taken like this. For all test a centos stream 9 devstack VM with local.conf included in the repository was used.

### no-profiler
This is a baseline test without any instrumentation enabled. Without any changes to any config.

- otel-collector was running in the background (doing nothing) to make sure this additional load doesn't impact the results when comparing them to later tests, which use otel-collector or jaeger as trace receiver.
- `./perf-test.sh --cycles 100 --result_file results/no-profiler.csv` was executed to run the test

### os-profiler-jaeger
This is a test with OSProfiler enabled. I used the snippet from osprofiler\_configs to configure OSProfiler on nova, keystone and glance. I also tried to enable it on Neutron, but I wasn't able to get any traces from it. This still partially worked though as I got all the related keystone traces from keystone <--> neutron communication. I used jaeger for receiving the traces as nova stopped working after installing the opentelemetry libraries. The created server would be for ever in the "BUILD" state.

Near the end an error occured, which distorted the second half of the results, but what's in the repository should still be enough.

- jaeger was running in the background to receive the metrics
- services were configured to collect db, requests and manually instrumented traces (services include manual OSProfiler instrumentation in their API).
- `./perf-test.sh --cycles 100 --result_file results/os-profiler-jaeger.csv --use_os_profiler` was executed to run the test.


### otel-autoinstrumentation-no-storage
This was an attempt to test with OTEL autoinstrumentation. Most of the traces come from wsgi, pymysql and requests instrumentations. Unfortunatelly I wasn't able to configure any receiver (otel-collector or jaeger) for some reason, so instead the traces are just outputted into the logs. I also wasn't able to make Nova work with the instrumentation. After like 5 times the scenario run the server would get stuck in the BUILD state. Similarly to Neutron with the OSProfiler, this was still able to get keystone traces related to Nova requests. Neutron isn't instrumented to mimic the configuration of the OSProfiler test.

- OTEL autoinstrumentation was installed by the commands included in otel-autoinstrumentation/install
- Service systemd unit files from otel-autoinstrumentation/systemd-unit-files/ were copied to /etc/systemd/system
- Devstack was restarted with `systemctl restart devstack@*`
- `./perf-test.sh --cycles 100 --result_file results/otel-autoinstrumentation-no-storage.csv` was executed to run the test.

## Measurement results.
The OSProfiler and OTEL autoinstrumentation scenarios as described above were similar in speed with an average slowdown compared to the baseline of about 2 %.

## Final thoughts
Unfortunatelly I wasn't able to get as close to "apples to apples" comparison as I hoped. I wasn't able to configure the transport for the traces for OTEL autoinstrumentation and I wasn't able to get Nova working with OTEL autoinstrumentation. This means, that there is quite a difference between the 2 tested scenarios. I think we could assume, that with autoinstrumented Nova and with traces being transported to some kind of receiver (instead of just being logged), the OTEL autoinstrumentation would be a little slower than what was measured.
