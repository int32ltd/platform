"""Layer 2: Capability Contract.

A contract declares, per verb, which fields are required/optional. It never
mentions a vendor. A request is only allowed to use verbs and fields the
contract declares.
"""
import yaml


def load_contract(path):
    with open(path) as f:
        return yaml.safe_load(f)


def validate(request, contract):
    """Raise ValueError on the first violation found. Returns nothing on success."""
    verbs = contract["verbs"]
    for key, params in request.items():
        if key == "capability":
            continue
        if key not in verbs:
            raise ValueError(f"verb '{key}' is not declared in contract '{contract['name']}'")
        spec = verbs[key]
        allowed = set(spec["required"]) | set(spec.get("optional", []))
        given = set(params.keys())
        missing = set(spec["required"]) - given
        if missing:
            raise ValueError(f"verb '{key}' is missing required field(s): {sorted(missing)}")
        unknown = given - allowed
        if unknown:
            raise ValueError(f"verb '{key}' has field(s) not declared in the contract: {sorted(unknown)}")
