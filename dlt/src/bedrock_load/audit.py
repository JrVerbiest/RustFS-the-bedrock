"""Audit: test the CSV files against their data contract, before anything is written."""

from pathlib import Path

import yaml
from datacontract.data_contract import DataContract
from datacontract.output.test_results_writer import print_test_results_table
from rich.console import Console


def audit(contract: str, folder: str) -> dict:
    """Test `<folder>/<table>.csv` against `contract` and print the results.

    The contract's own `servers` are replaced by `folder`, so the contract is tested against
    the files that are about to be written.

    Parameters
    ----------
    contract : str
        Path to the data contract (ODCS YAML).
    folder : str
        Folder holding one `<table>.csv` per table in the contract.

    Returns
    -------
    dict
        The data contract.

    Raises
    ------
    SystemExit
        If no check ran, or any check did not pass.
    """
    spec = yaml.safe_load(Path(contract).read_text())
    spec["servers"] = [
        {"server": "audit", "type": "local", "format": "csv", "path": f"{folder}/{{model}}.csv"}
    ]
    run = DataContract(data_contract_str=yaml.safe_dump(spec), server="audit").test()

    console = Console()
    print_test_results_table(run, console)  # the same table as `datacontract test`
    if not run.checks or any(check.result != "passed" for check in run.checks):
        raise SystemExit("🔴 Audit failed: nothing written.")
    console.print(f"🟢 Audit passed: {len(run.checks)} checks.")
    return spec
