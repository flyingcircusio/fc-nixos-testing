import json
import unittest.mock
from unittest.mock import MagicMock

import fc.maintenance.cli
import pytest
import typer.testing

CHANNEL_URL = (
    "https://hydra.flyingcircus.io/build/138288/download/1/nixexprs" ".tar.xz"
)
ENVIRONMENT = "test"

ENC = {
    "parameters": {
        "machine": "virtual",
        "environment": ENVIRONMENT,
        "environment_url": CHANNEL_URL,
    }
}


@pytest.fixture
def app_main_args(tmp_path, agent_maintenance_config):
    enc_file = tmp_path / "enc.json"
    (tmp_path / "fc-agent").mkdir()
    enc_file.write_text(json.dumps(ENC), encoding="utf8")

    return (
        "--verbose",
        "--show-caller-info",
        "--spooldir",
        tmp_path,
        "--logdir",
        tmp_path,
        "--lock-dir",
        tmp_path,
        "--config-file",
        agent_maintenance_config,
        "--enc-path",
        enc_file,
    )


@pytest.fixture
def _invoke_app(app_main_args, monkeypatch):
    def _invoke_app_wrapper(*args, exit_code=0):
        runner = typer.testing.CliRunner()

        with unittest.mock.patch("fc.maintenance.cli.ReqManager"):
            result = runner.invoke(
                fc.maintenance.cli.app, app_main_args + args
            )
            assert (
                result.exit_code == exit_code
            ), f"unexpected exit code {result.exit_code}, output: {result.output}"

    return _invoke_app_wrapper


@pytest.fixture
def invoke_app_as_root(_invoke_app, monkeypatch):
    monkeypatch.setattr("os.getuid", lambda: 0)
    return _invoke_app


@pytest.fixture
def invoke_app_as_normal_user(_invoke_app, monkeypatch):
    monkeypatch.setattr("os.getuid", lambda: 1000)
    return _invoke_app


def test_invoke_schedule(invoke_app_as_root):
    invoke_app_as_root("schedule")
    fc.maintenance.cli.rm.schedule.assert_called_once()


def test_invoke_run(invoke_app_as_root):
    invoke_app_as_root("run")
    fc.maintenance.cli.rm.execute.assert_called_once_with(False, False)
    fc.maintenance.cli.rm.postpone.assert_called_once()
    fc.maintenance.cli.rm.archive.assert_called_once()


def test_invoke_run_as_normal_user_should_fail(invoke_app_as_normal_user):
    invoke_app_as_normal_user("run", exit_code=77)


def test_invoke_run_all_now(invoke_app_as_root):
    invoke_app_as_root("run", "--run-all-now")
    fc.maintenance.cli.rm.execute.assert_called_once_with(True, False)


def test_invoke_run_all_now_force_run(invoke_app_as_root):
    invoke_app_as_root("run", "--run-all-now", "--force-run")
    fc.maintenance.cli.rm.execute.assert_called_once_with(True, True)


def test_invoke_delete(invoke_app_as_root):
    invoke_app_as_root("delete", "123abc")
    fc.maintenance.cli.rm.delete.assert_called_once_with("123abc")


@pytest.mark.parametrize(
    "args",
    [
        ["schedule"],
        ["run"],
        ["delete", "123abc"],
        ["request", "script", "comment", "true"],
        ["request", "reboot"],
        ["request", "update"],
        ["request", "system-properties"],
    ],
)
def test_invoke_root_cmds_as_normal_user_should_fail(
    args,
    invoke_app_as_normal_user,
):
    invoke_app_as_normal_user(*args, exit_code=77)


def test_invoke_list(invoke_app_as_normal_user):
    invoke_app_as_normal_user("list")
    fc.maintenance.cli.rm.list_requests.assert_called_once()


def test_invoke_show(invoke_app_as_normal_user):
    invoke_app_as_normal_user("show")
    fc.maintenance.cli.rm.show_request.assert_called_once()


def test_invoke_show_request_id_dump_yaml(invoke_app_as_normal_user):
    invoke_app_as_normal_user("show", "123abc", "--dump-yaml")
    fc.maintenance.cli.rm.show_request.assert_called_once_with("123abc", True)


def test_invoke_request_run_script(invoke_app_as_root):
    invoke_app_as_root("request", "script", "comment", "true")
    fc.maintenance.cli.rm.add.assert_called_once()


@unittest.mock.patch("fc.maintenance.cli.RebootActivity")
def test_invoke_request_warm_reboot(activity, invoke_app_as_root):
    invoke_app_as_root("request", "reboot")
    activity.assert_called_once_with("reboot")
    fc.maintenance.cli.rm.add.assert_called_once()


@unittest.mock.patch("fc.maintenance.cli.RebootActivity")
def test_invoke_request_cold_reboot(activity, invoke_app_as_root):
    invoke_app_as_root("request", "reboot", "--cold-reboot")
    activity.assert_called_once_with("poweroff")
    fc.maintenance.cli.rm.add.assert_called_once()


@unittest.mock.patch("fc.maintenance.cli.request_reboot_for_kernel")
@unittest.mock.patch("fc.maintenance.cli.request_reboot_for_kvm_environment")
@unittest.mock.patch("fc.maintenance.cli.request_reboot_for_cpu")
@unittest.mock.patch("fc.maintenance.cli.request_reboot_for_memory")
def test_invoke_request_system_properties_virtual(
    memory, cpu, qemu, kernel, invoke_app_as_root
):
    invoke_app_as_root("request", "system-properties")
    memory.assert_called_once()
    cpu.assert_called_once()
    qemu.assert_called_once()
    kernel.assert_called_once()


@unittest.mock.patch("fc.maintenance.cli.request_reboot_for_kernel")
@unittest.mock.patch("fc.maintenance.cli.request_reboot_for_kvm_environment")
@unittest.mock.patch("fc.maintenance.cli.request_reboot_for_cpu")
@unittest.mock.patch("fc.maintenance.cli.request_reboot_for_memory")
def test_invoke_request_system_properties_physical(
    memory, cpu, qemu, kernel, tmpdir, invoke_app_as_root
):
    enc_file = tmpdir / "enc.json"
    enc = ENC.copy()
    enc["parameters"]["machine"] = "physical"
    enc_file.write_text(json.dumps(enc), encoding="utf8")

    invoke_app_as_root("request", "system-properties")
    memory.assert_not_called()
    cpu.assert_not_called()
    qemu.assert_not_called()
    kernel.assert_called_once()


@unittest.mock.patch("fc.maintenance.cli.request_update")
@unittest.mock.patch("fc.maintenance.cli.load_enc")
def test_invoke_request_update(load_enc, request_update, invoke_app_as_root):
    invoke_app_as_root("request", "update")
    load_enc.assert_called_once()
    request_update.assert_called_once()
    fc.maintenance.cli.rm.add.assert_called_once()


@unittest.mock.patch("fc.util.directory.is_node_in_service")
def test_invoke_constraints(
    is_node_in_service, monkeypatch, invoke_app_as_root, log
):
    monkeypatch.setattr("fc.util.directory.connect", MagicMock())
    invoke_app_as_root("constraints", "--in-service", "test01")
    is_node_in_service.assert_called_with(unittest.mock.ANY, "test01")
    assert log.debug("constraints-check-in-service", machine="test01")
    assert log.debug("constraints-success")


@unittest.mock.patch("fc.util.directory.is_node_in_service")
def test_invoke_constraints_not_met(
    is_node_in_service, monkeypatch, invoke_app_as_root, log
):
    monkeypatch.setattr("fc.util.directory.connect", MagicMock())
    is_node_in_service.return_value = False
    invoke_app_as_root("constraints", "--in-service", "test01", exit_code=69)
    assert log.info("constraints-failure")


def test_invoke_metrics(app_main_args):
    runner = typer.testing.CliRunner()
    with unittest.mock.patch("fc.maintenance.cli.ReqManager") as rm:
        rm.return_value.get_metrics.return_value = {}
        result = runner.invoke(
            fc.maintenance.cli.app, app_main_args + ("metrics",)
        )
        assert (
            not result.exit_code
        ), f"unexpected exit code {result.exit_code}, output: {result.output}"
