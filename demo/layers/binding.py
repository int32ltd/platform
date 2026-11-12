"""Layer 4: Binding Policy.

The only layer allowed to name a vendor. Pure data lookup: given a tenant and
an environment, which provider handles this capability right now. Rules are
evaluated top-to-bottom, first match wins.
"""
import yaml


def load_bindings(path):
    with open(path) as f:
        return yaml.safe_load(f)


def _matches(pattern, value):
    return pattern == "*" or pattern == value


def resolve(bindings, tenant, environment):
    for rule in bindings["rules"]:
        match = rule["match"]
        if _matches(match["tenant"], tenant) and _matches(match["environment"], environment):
            return rule["provider"]
    raise ValueError("no binding rule matched — the policy must end in a */* default")
