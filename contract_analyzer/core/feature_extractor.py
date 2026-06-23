import json
import numpy as np

SIG_MAP = {
    "0x82be0b96": "collateralToken",
    "0x23b872dd": "transferFrom",
    "0xa9059cbb": "transfer",
    "0x095ea7b3": "approve",
    "0x40c10f19": "mint",
    "0x42966c68": "burn",
    "0x4e71d92d": "withdraw",
    "0x2e1a7d4d": "withdraw",
    "0x3ccfd60b": "flashLoan",
    "0x5cffe9de": "flashLoan",
    "0x1e2e5690": "swap",
    "0x38ed1739": "swap",
    "0x7c025200": "flashLoan",
    "0xcdc2e466": "withdraw",
    "0xd0e30db0": "deposit",
    "0x6a627842": "mint",
    "0x313ce567": "decimals",
    "0x06fdde03": "name",
    "0x95d89b41": "symbol",
    "0x18160ddd": "totalSupply",
}

def safe_parse_hex(hex_str):
    if not isinstance(hex_str, str):
        return str(hex_str)
    if hex_str.startswith("0x") and len(hex_str) >= 10:
        key = hex_str[:10].lower()
        return SIG_MAP.get(key, hex_str)
    return hex_str

def extract_features_from_json_v2(json_str):
    try:
        data = json.loads(json_str)
    except:
        data = {}

    calls = data.get("function_call", [])
    if not calls:
        for v in data.values():
            if isinstance(v, list):
                calls = v
                break
        if not calls:
            calls = []

    def traverse(clist, depth=0):
        info = {
            "call_count": 0,
            "event_count": 0,
            "max_depth": depth,
            "contracts": set(),
            "has_transfer": False,
            "has_approve": False,
            "has_flashloan": False,
            "has_delegatecall": False,
            "has_selfdestruct": False,
            "has_high_value": False,
            "value_list": [],
            "func_signatures": [],
            "total_value": 0.0,
        }
        if not isinstance(clist, list):
            return info

        for call in clist:
            if not isinstance(call, dict):
                continue

            info["call_count"] += 1
            func_raw = call.get("func", call.get("function", ""))
            func_name = safe_parse_hex(func_raw) if func_raw else ""
            info["func_signatures"].append(func_name)

            contract = call.get("contract", call.get("to", ""))
            if contract and isinstance(contract, str):
                info["contracts"].add(contract)

            ctype = call.get("type", "").upper()
            if ctype == "EVENT":
                info["event_count"] += 1

            if "transfer" in func_name.lower():
                info["has_transfer"] = True
            if "approve" in func_name.lower():
                info["has_approve"] = True
            if "flash" in func_name.lower():
                info["has_flashloan"] = True
            if "delegatecall" in ctype or func_name.lower() == "delegatecall":
                info["has_delegatecall"] = True
            if "selfdestruct" in func_name.lower():
                info["has_selfdestruct"] = True

            val_str = call.get("value", "0")
            try:
                if isinstance(val_str, str) and val_str.startswith("0x"):
                    val = float(int(val_str, 16))
                else:
                    val = float(val_str)
                if np.isfinite(val) and val <= 1e30:
                    info["value_list"].append(val)
                    info["total_value"] += val
                    if val > 1e18:
                        info["has_high_value"] = True
            except:
                pass

            sub_calls = call.get("internal_calls", [])
            if not sub_calls:
                sub_calls = call.get("calls", [])
            child = traverse(sub_calls, depth + 1)

            info["call_count"] += child["call_count"]
            info["event_count"] += child["event_count"]
            info["max_depth"] = max(info["max_depth"], child["max_depth"])
            info["contracts"].update(child["contracts"])
            info["has_transfer"] = info["has_transfer"] or child["has_transfer"]
            info["has_approve"] = info["has_approve"] or child["has_approve"]
            info["has_flashloan"] = info["has_flashloan"] or child["has_flashloan"]
            info["has_delegatecall"] = info["has_delegatecall"] or child["has_delegatecall"]
            info["has_selfdestruct"] = info["has_selfdestruct"] or child["has_selfdestruct"]
            info["has_high_value"] = info["has_high_value"] or child["has_high_value"]
            info["value_list"].extend(child["value_list"])
            info["total_value"] += child["total_value"]
            info["func_signatures"].extend(child["func_signatures"])

        return info

    stats = traverse(calls)

    call_count = stats["call_count"]
    event_count = stats["event_count"]
    max_depth = stats["max_depth"]
    unique_contracts = len(stats["contracts"])
    has_transfer = int(stats["has_transfer"])
    has_approve = int(stats["has_approve"])
    has_flashloan = int(stats["has_flashloan"])
    has_delegatecall = int(stats["has_delegatecall"])
    has_selfdestruct = int(stats["has_selfdestruct"])
    has_high_value = int(stats["has_high_value"])
    total_value = stats["total_value"]
    if total_value > 1e30:
        total_value = 1e30
    max_value = max(stats["value_list"]) if stats["value_list"] else 0.0
    if max_value > 1e30:
        max_value = 1e30
    unique_signatures = len(set(stats["func_signatures"]))
    unknown_sig_count = sum(1 for s in stats["func_signatures"] if isinstance(s, str) and s.startswith("0x") and len(s) >= 10)

    feat = [
        call_count,
        event_count,
        max_depth,
        unique_contracts,
        has_transfer,
        has_approve,
        has_flashloan,
        has_delegatecall,
        has_selfdestruct,
        has_high_value,
        total_value,
        max_value,
        unique_signatures,
        unknown_sig_count,
    ]
    feat = [0.0 if not np.isfinite(f) else f for f in feat]
    return feat