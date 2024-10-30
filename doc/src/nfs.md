(nixos-nfs)=

# NFS

Maintains a NFS share to access a data pool from multiple VMs. The NFS share is
bound to one project and one datacenter location.

## Components

- nfs_rg_share
- nfs_rg_client

## Configuration

The NFS configuration is fully managed and located in
{file}`/etc/exports` for the NFS server and {file}`/etc/fstab` for the NFS
clients.

The NFS server is by default set up to run in sync mode, so any system call that
writes data to files on the NFS share causes that data to be flushed to the
server before the system call returns control to user space. This provides
greater data cache coherence among clients, but at a significant performance
cost.

The NFS clients are connected in `hard` mode to ensure data consistency. In
addition we use an automount unit, to avoid applications unexpectedly running
without access to NFS due to mounting issues at boot time. If NFS is absent
applications will experience infinite blocking or receive explicit errors
when accessing NFS-backed paths.

**flyingcircus.roles.nfs_rg_share.clientFlags**

List of strings that are applied as options for every client.

Default: `["rw" "sync" "root_squash" "no_subtree_check"]`


## Interaction

All NFS clients mount the NFS share at {file}`/mnt/nfs/shared`. This directory is
readable and writable by any service user. Application may use this directory to
store their data to be available across multiple VMs.

The NFS server stores its data at {file}`/srv/nfs/shared`. This directory is also
readable and writable by any service user. We recommend not to directly access
this directory if there is no special need to do so, but to also use the NFS
client component on the server VM.

% vim: set spell spelllang=en:
