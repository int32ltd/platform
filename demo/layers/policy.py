"""Layer 3: Policy & Ownership Graph.

Ownership lives here, in exactly one place (Component -> owner Team -> grants).
Vendor-native IAM, in the real design, is a generated projection of this graph
and is never hand-edited — this demo only models the graph side.
"""
import yaml

CATALOG_DIR = "catalog"
COMPONENTS_PATH = f"{CATALOG_DIR}/components.yaml"
TEAMS_PATH = f"{CATALOG_DIR}/teams.yaml"


def load_catalog():
    with open(COMPONENTS_PATH) as f:
        components = yaml.safe_load(f)["components"]
    with open(TEAMS_PATH) as f:
        teams = yaml.safe_load(f)["teams"]
    return components, teams


def check_access(component, team, capability):
    """Does `team` own `component`, and does that team's role grant `capability`?"""
    components, teams = load_catalog()
    if component not in components:
        return False, f"component '{component}' is not registered in the catalog"
    actual_owner = components[component]["owner"]
    if actual_owner != team:
        return False, f"'{team}' does not own '{component}' (owner is '{actual_owner}')"
    if team not in teams:
        return False, f"team '{team}' is not registered in the catalog"
    if capability not in teams[team]["grants"]:
        return False, f"'{team}' has no role granting capability '{capability}'"
    return True, f"'{team}' owns '{component}' and is granted '{capability}'"


def explain(component, team):
    """Mirror `policy-cli explain` — the graph path that produced the decision."""
    components, teams = load_catalog()
    owner = components.get(component, {}).get("owner", "<unknown>")
    grants = teams.get(team, {}).get("grants", [])
    allowed, reason = check_access(component, team, "observability")
    path = f"Component({component}) --owned-by--> Team({owner}) --grants--> {grants}"
    return path, allowed, reason


def transfer_ownership(component, new_team):
    """The one-field edit that moves ownership — everything downstream recalculates from it."""
    with open(COMPONENTS_PATH) as f:
        data = yaml.safe_load(f)
    old_team = data["components"][component]["owner"]
    data["components"][component]["owner"] = new_team
    with open(COMPONENTS_PATH, "w") as f:
        yaml.safe_dump(data, f, sort_keys=False)
    return old_team
