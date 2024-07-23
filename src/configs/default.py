import platform, pathlib
import schemas

def assemble(
  workdir: str = '/mnt/build',
  target_arch: str = platform.machine()
) -> schemas.BuildConfig:
  """Assemble a default Build Configuration"""
  _workdir = pathlib.Path(workdir)
  rootfs_cfg: schemas.RootFSConfig = {
    'artifact_path': (_workdir / 'rootfs.tar.xz').as_posix(),
    'fmt': 'tar.xz',
  }
  blk_devs: list[schemas.BlkDevCfg] = [
    {
      'kind': 'raw',
      'path': (_workdir / 'rootfs.img').as_posix(),
      'size': '4GiB',
      'fs_type': 'ext4',
      'volume_label': 'ROOT',
      # Allow UUID to be auto-generated
      'mount_point': (_workdir / 'rootfs').as_posix(),
    }
  ]
  os_cfg: schemas.OSConfig = {
    'release': 'alpine',
    'version': '3.19',
  }
  kernel_cfg: schemas.KernelCfg = {
    'path': (_workdir / 'linux').as_posix(),
    'version': '6.6.30',
    # TODO: Move these elsewhere
    'patch_path': (_workdir / 'linux-patches').as_posix(),
    'patch_src': 'alpine',
    'patch_ref': '3.19-stable',
    'patch_kind': 'lts',
  }
  return {
    'workdir': _workdir.as_posix(),
    'target_arch': target_arch,
    'rootfs': rootfs_cfg,
    'block_devices': blk_devs,
    'os': os_cfg,
    'kernel': kernel_cfg,
  }