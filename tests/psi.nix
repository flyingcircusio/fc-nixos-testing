import ./make-test-python.nix ({ testlib, ... }:
{
  name = "psi";
  testCases = {
    justpsi = {
      name = "justpsi";
      nodes.machine = { lib, ... }:
      {
        imports = [ (testlib.fcConfig { net.fe = false; }) ];
        services.telegraf.enable = true;
      };
      testScript = ''
        start_all()
        machine.wait_for_unit("telegraf.service")
        with subtest("psi data should show up and no cgroup data should pop up"):
          machine.wait_until_succeeds("curl machine:9126/metrics | grep psi")
          machine.fail("curl machine:9126/metrics | grep cgroup")
      '';
    };
    psicgroup = {
      name = "psicgroup";
      nodes.machine = { lib, ... }:
      {
        imports = [ (testlib.fcConfig { net.fe = false; }) ];
        flyingcircus.services.telegraf.psiCgroupRegex = [ ".*\\.service" ];
        services.telegraf.enable = true;
      };
      testScript = ''
        start_all()
        machine.wait_for_unit("telegraf.service")
        with subtest("psi data should show up and cgroup data should also show up"):
          machine.wait_until_succeeds("curl machine:9126/metrics | grep psi")
          machine.succeed("curl machine:9126/metrics | grep cgroup")
      '';
    };
  };
})
