#!/usr/bin/env python3
"""Tiny CLI entrypoint standing in for Layer 1 (Developer Interface).

Run `python3 platform.py apply ...` (and see README.md for the full walkthrough).
"""
import argparse
import sys

import yaml

from layers import adapters, binding, contract, policy

CONTRACT_PATH = "contracts/observability.yaml"
BINDINGS_PATH = "bindings/observability.yaml"


def cmd_apply(args):
    print(f"[1 Developer Interface] read request '{args.request_file}'")
    with open(args.request_file) as f:
        request = yaml.safe_load(f)
    print(f"    {request}")

    print(f"[2 Capability Contract] validating against '{CONTRACT_PATH}'")
    cap = request["capability"]
    cap_contract = contract.load_contract(CONTRACT_PATH)
    try:
        contract.validate(request, cap_contract)
    except ValueError as e:
        print(f"    REJECTED: {e}")
        sys.exit(1)
    print("    ok — every verb/field is declared in the contract")

    print(f"[3 Policy & Ownership Graph] does '{args.team}' own '{args.component}' "
          f"and may it use '{cap}'?")
    allowed, reason = policy.check_access(args.component, args.team, cap)
    print(f"    {'ALLOWED' if allowed else 'DENIED'} — {reason}")
    if not allowed:
        sys.exit(1)

    print(f"[4 Binding Policy] resolving provider for tenant='{args.tenant}' "
          f"environment='{args.environment}'")
    bindings = binding.load_bindings(BINDINGS_PATH)
    provider = binding.resolve(bindings, args.tenant, args.environment)
    print(f"    -> provider: {provider}")

    print(f"[5 Provider Adapter] translating verbs for '{provider}'")
    print(f"[6 Concrete Vendor] (simulated) calls:")
    adapters.apply(provider, request)


def cmd_transfer_ownership(args):
    old_team = policy.transfer_ownership(args.component, args.new_team)
    print(f"[Ownership Graph] '{args.component}': owner changed '{old_team}' -> '{args.new_team}'")
    print(f"    (one field edited in {policy.COMPONENTS_PATH}; re-run `explain` or `apply` "
          f"to see access recalculate)")


def cmd_explain(args):
    path, allowed, reason = policy.explain(args.component, args.team)
    print(f"[Policy & Ownership Graph] graph path:")
    print(f"    {path}")
    print(f"[decision for team='{args.team}'] {'ALLOWED' if allowed else 'DENIED'} — {reason}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_apply = sub.add_parser("apply", help="run a request through every layer")
    p_apply.add_argument("request_file")
    p_apply.add_argument("--component", required=True)
    p_apply.add_argument("--team", required=True)
    p_apply.add_argument("--tenant", required=True)
    p_apply.add_argument("--environment", required=True)
    p_apply.set_defaults(func=cmd_apply)

    p_transfer = sub.add_parser("transfer-ownership", help="move a component to a new owning team")
    p_transfer.add_argument("--component", required=True)
    p_transfer.add_argument("--new-team", required=True)
    p_transfer.set_defaults(func=cmd_transfer_ownership)

    p_explain = sub.add_parser("explain", help="show the graph path behind an access decision")
    p_explain.add_argument("--component", required=True)
    p_explain.add_argument("--team", required=True)
    p_explain.set_defaults(func=cmd_explain)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
