# credential-store-fs-matrix — does the credential-store permission contract hold on every mainstream
# filesystem, not just the ZFS box it was developed on?
#
# A NixOS VM test (QEMU, no host root needed): three raw disks are formatted ext4 / xfs / btrfs (plus a
# tmpfs mount — all four share the generic VFS setattr path), and on each the EXACT layout mechanics the
# CLI performs are exercised as real users:
#
#   * root creates the type dir `3777 root:nixbld` (setgid + sticky + world-writable, the /tmp model);
#   * an unprivileged human NOT in `nixbld` creates their account dir with a RAW umask-027 mkdir — this
#     must come out `2750 <user>:nixbld`, i.e. the setgid bit and group must be INHERITED and survive.
#     The negative control right next to it shows why the code must never `install -d -m`/`mkdir -m`
#     there: the post-mkdir chmod by a non-member without CAP_FSETID is stripped of setgid by the kernel
#     (`setattr_prepare`) on all four of these filesystems — silently, chmod still "succeeds". (ZFS
#     retains the bit, which is exactly how the bug stayed invisible during development.)
#   * the token is installed `0640` with no `-g` and must inherit group `nixbld` from the setgid dir;
#   * a build-group process (primary gid `nixbld` — the only gid that reaches a user-namespaced builder)
#     can read the token; another human can neither read it nor traverse the account dir; the sticky
#     type dir keeps that other human from deleting or renaming the account dir out from under its owner;
#   * the artifact cache's self-heal prerequisite holds: in the NON-sticky 0777 cache dir a build-group
#     process can unlink another writer's unreadable entry and replace it with its own.
#
# Run it directly (needs KVM):
#   nix build --impure --expr 'import ./nixos/tests/credential-store-fs-matrix.nix { pkgs = import (builtins.getFlake (toString ./.)).inputs.nixpkgs { system = builtins.currentSystem; }; }'
#
# Deliberately NOT in `checks` (a QEMU VM per `nix flake check` is too heavy for that gate); it exists to
# be run when the store contract or `cred/store.rs`'s layout code changes.
#
# SCOPE: this covers the CLI's UNPRIVILEGED raw-mkdir layout mechanics across filesystems. The DECLARATIVE
# materializer (`propnix cred materialize`, run as root by the module) is exercised end to end — install,
# prune, convergence, and its symlink/foreign-entry refusals — by the unit tests in
# `pkgs/propnix-cli/src/cred/materialize.rs`, which run in the crate's `doCheck` (unprivileged, stamping the
# test user's own uid/gid through the identical fd-based code path the root service uses).
{ pkgs }:
pkgs.testers.runNixOSTest {
  name = "propnix-credential-store-fs-matrix";

  nodes.machine =
    { pkgs, ... }:
    {
      # ≥512 MiB each: current mkfs.xfs refuses filesystems under 300 MiB.
      virtualisation.emptyDiskImages = [
        512
        512
        512
      ];
      environment.systemPackages = with pkgs; [
        e2fsprogs
        xfsprogs
        btrfs-progs
      ];
      # alice = the human adding a credential; carol = some other human. Neither is in nixbld (a human
      # must never be — nix would pick them to run builds as). buildproc stands in for a sandboxed
      # builder: what reaches a user-namespaced build is exactly its PRIMARY gid (nixbld), which is what
      # this user has; the userns gid-survival itself is verified live on real hosts.
      users.users.alice.isNormalUser = true;
      users.users.carol.isNormalUser = true;
      users.users.buildproc = {
        isSystemUser = true;
        group = "nixbld";
        useDefaultShell = true;
      };
    };

  testScript = ''
    machine.wait_for_unit("multi-user.target")

    def as_user(user, cmd):
        return f"su {user} -s /bin/sh -c '{cmd}'"

    def mode_group(path):
        return machine.succeed(f"stat -c '%a %G' {path}").strip()

    def check_store_contract(m):
        """The full layout battery on a store rooted at mount point m."""
        steam = f"{m}/steam"

        # Type dir: root creates it 3777 root:nixbld (root holds CAP_FSETID, so setgid sticks).
        machine.succeed(f"install -d -m 3777 -g nixbld {steam}")
        assert mode_group(steam) == "3777 nixbld", f"{steam}: {mode_group(steam)}"

        # THE LOAD-BEARING STEP — alice's raw umask-027 mkdir must inherit setgid + group nixbld.
        machine.succeed(as_user("alice", f"umask 027; mkdir {steam}/alice"))
        got = mode_group(f"{steam}/alice")
        assert got == "2750 nixbld", f"raw mkdir on {m}: want '2750 nixbld', got '{got}'"

        # NEGATIVE CONTROLS — why the code above must issue NEITHER chmod NOR chown after the mkdir.
        # (1) chmod: an explicit `chmod 2750` by the owner, who is NOT a member of the dir's group and has
        # no CAP_FSETID, "succeeds" (rc=0) but the kernel silently strips S_ISGID → 0750. Generic-VFS
        # behavior, so asserted on every filesystem here (measured on ZFS too, outside this test).
        machine.succeed(as_user("alice", f"umask 027; mkdir {steam}/alice-chmod && chmod 2750 {steam}/alice-chmod"))
        got = mode_group(f"{steam}/alice-chmod")
        assert got == "750 nixbld", f"chmod strip control on {m}: want '750 nixbld', got '{got}'"
        # (2) chown — INFORMATIONAL, because the outcome demonstrably varies by kernel/filesystem: on the
        # development host (ZFS) an unprivileged chown-to-self cleared a dir's setgid (the pre-fix
        # `install -d -o` layout bug), while ext4 in this VM retains it. Either behavior is permitted;
        # the code must simply never chown a fresh account dir (the creator already owns it).
        machine.succeed(as_user("alice", f"umask 027; mkdir {steam}/alice-chown && chown alice {steam}/alice-chown"))
        got = mode_group(f"{steam}/alice-chown")
        assert got.endswith(" nixbld"), f"chown control group on {m}: got '{got}'"
        print(f"informational: chown-to-self after raw mkdir on {m} -> {got}")

        # Token: installed 0640, NO -g — inherits nixbld from the setgid account dir.
        machine.succeed(as_user("alice", f"printf secret > /tmp/tok && install -m 0640 -o $(id -u) /tmp/tok {steam}/alice/token"))
        got = mode_group(f"{steam}/alice/token")
        assert got == "640 nixbld", f"token on {m}: want '640 nixbld', got '{got}'"

        # The two permitted readers, and nobody else.
        machine.succeed(as_user("alice", f"cat {steam}/alice/token > /dev/null"))
        machine.succeed(as_user("buildproc", f"cat {steam}/alice/token > /dev/null"))
        machine.fail(as_user("carol", f"cat {steam}/alice/token"))
        machine.fail(as_user("carol", f"ls {steam}/alice"))

        # Sticky type dir: carol can create her own account dir but cannot remove or rename alice's.
        machine.fail(as_user("carol", f"rm -rf {steam}/alice"))
        machine.fail(as_user("carol", f"mv {steam}/alice {steam}/stolen"))
        machine.succeed(as_user("carol", f"umask 027; mkdir {steam}/carol"))

        # Cache self-heal prerequisite: NON-sticky 0777 dir — buildproc may replace alice's entry (which
        # it cannot read) with its own; alice in turn cannot read buildproc's (0640, group nixbld).
        cache = f"{m}/cache/steam"
        machine.succeed(f"install -d -m 0777 {m}/cache")  # the store bootstrap's job (module/CLI)
        machine.succeed(as_user("alice", f"mkdir {cache} && chmod 0777 {cache}"))
        machine.succeed(as_user("alice", f"umask 137; printf hostkey > {cache}/depot-1.key"))
        machine.fail(as_user("buildproc", f"cat {cache}/depot-1.key"))
        # `rm -f`: the real writer unlinks via `std::fs::remove_file` (unlink(2)) which never prompts;
        # bare coreutils `rm` on a file the caller can't write would prompt and, with no tty, hang.
        machine.succeed(as_user("buildproc", f"rm -f {cache}/depot-1.key && umask 137; printf buildkey > {cache}/depot-1.key"))
        got = mode_group(f"{cache}/depot-1.key")
        assert got == "640 nixbld", f"healed cache entry on {m}: want '640 nixbld', got '{got}'"
        machine.fail(as_user("alice", f"cat {cache}/depot-1.key"))
        machine.succeed(as_user("buildproc", f"cat {cache}/depot-1.key > /dev/null"))

        print(f"contract holds on {m}")

    # Format and mount the matrix.
    machine.succeed("mkfs.ext4 -q /dev/vdb && mkdir -p /mnt/ext4 && mount /dev/vdb /mnt/ext4")
    machine.succeed("mkfs.xfs -f /dev/vdc > /dev/null && mkdir -p /mnt/xfs && mount /dev/vdc /mnt/xfs")
    machine.succeed("mkfs.btrfs -f -q /dev/vdd && mkdir -p /mnt/btrfs && mount /dev/vdd /mnt/btrfs")
    machine.succeed("mkdir -p /mnt/tmpfs && mount -t tmpfs tmpfs /mnt/tmpfs")

    for m in ["/mnt/ext4", "/mnt/xfs", "/mnt/btrfs", "/mnt/tmpfs"]:
        check_store_contract(m)
  '';
}
