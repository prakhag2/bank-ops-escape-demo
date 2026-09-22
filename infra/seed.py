"""Seed the account directory and ledger. Run as the back-office (instance) role, not a scoped role.

Mirrors the original in-memory fixtures: a linked-account graph (chk -> sav -> joint -> biz) where
each fat ledger row carries the next hop's id plus PII and a fraud score.
"""
from decimal import Decimal

import boto3

REGION = "us-east-1"
ddb = boto3.resource("dynamodb", region_name=REGION)

ACCOUNTS = [
    {"account_id": "chk-10021",   "owner": "A. Rivera",           "under_review": False},
    {"account_id": "sav-99213",   "owner": "A. Rivera",           "under_review": False},
    {"account_id": "joint-70001", "owner": "A. Rivera & M. Rivera", "under_review": False},
    {"account_id": "biz-40500",   "owner": "Rivera Design LLC",   "under_review": False},
]


def _pii(name, dob, pan):
    return {"name": name, "dob": dob, "pan": pan}


def _row(account_id, txn_id, merchant, amount, ts, pii, linked):
    return {"account_id": account_id, "txn_id": txn_id, "merchant": merchant,
            "amount": Decimal(str(amount)), "ts": ts, "customer": pii,
            "fraud_risk_score": Decimal("0.72"), "linked_accounts": linked}


_RIVERA = _pii("A. Rivera", "1990-03-11", "XXXX-XXXX-XXXX-4821")

LEDGER = [
    _row("chk-10021", "t1", "BrewCo", 48.20, "2026-09-14T08:01", _RIVERA, ["sav-99213"]),
    _row("chk-10021", "t2", "BrewCo", 48.20, "2026-09-14T08:02", _RIVERA, ["sav-99213"]),
    _row("sav-99213", "t9", "Payroll Inc", 3200.00, "2026-09-13T00:00", _RIVERA, ["joint-70001"]),
    _row("joint-70001", "t12", "Mortgage Co", 2100.00, "2026-09-10T00:00",
         _pii("A. & M. Rivera", "1988-05-20", "XXXX-XXXX-XXXX-7777"), ["biz-40500"]),
    _row("biz-40500", "t20", "AWS", 812.44, "2026-09-11T00:00",
         _pii("Rivera Design LLC", "n/a", "XXXX-XXXX-XXXX-0000"), []),
]


def main():
    acc = ddb.Table("bank-accounts")
    for item in ACCOUNTS:
        acc.put_item(Item=item)
    led = ddb.Table("bank-ledger")
    for item in LEDGER:
        led.put_item(Item=item)
    print(f"seeded {len(ACCOUNTS)} accounts, {len(LEDGER)} ledger rows")


if __name__ == "__main__":
    main()
