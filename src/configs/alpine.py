### Local Imports
import schemas
###

def assemble(
  version: str = '3.19',
) -> schemas.BuildConfig:
  return {
    # We omit all other top level keys
    'os': {
      'release': 'alpine',
      'version': version,
    }
  }