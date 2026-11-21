"""Layer 4/6: Provider Adapter + (simulated) Concrete Vendor.

Each adapter translates the same vendor-neutral verbs into a vendor-shaped
call. No adapter does anything but translate — the vendor call itself is
simulated (printed), never actually made.
"""


def datadog_adapter(verb, params):
    if verb == "emit-metric":
        print(f"    POST https://api.datadoghq.com/api/v1/series")
        print(f"    body: {{'metric': '{params['name']}', 'type': '{params['type']}'}}")
    elif verb == "define-alert":
        print(f"    POST https://api.datadoghq.com/api/v1/monitor")
        print(f"    body: {{'type': 'metric alert', 'query': '{params['condition']}', "
              f"'tags': ['severity:{params['severity']}']}}")


def dynatrace_adapter(verb, params):
    if verb == "emit-metric":
        print(f"    POST https://.live.dynatrace.com/api/v2/metrics/ingest")
        print(f"    body: '{params['name']},type={params['type']} value'")
    elif verb == "define-alert":
        print(f"    POST https://.live.dynatrace.com/api/config/v1/anomalyDetection/metricEvents")
        print(f"    body: {{'metricId': '{params['metric']}', 'threshold': '{params['condition']}', "
              f"'severity': '{params['severity']}'}}")


ADAPTERS = {
    "datadog": datadog_adapter,
    "dynatrace": dynatrace_adapter,
}


def apply(provider, request):
    adapter = ADAPTERS[provider]
    for verb, params in request.items():
        if verb == "capability":
            continue
        adapter(verb, params)
