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
  return {
    'workdir': _workdir.as_posix(),
    'target_arch': target_arch,
    'rootfs': rootfs_cfg,
    'block_devices': blk_devs,
    'os': os_cfg,
  }