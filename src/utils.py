import re

IE_MULTIPLIERS = {
  'KiB': 1024**1, 'MiB': 1024**2, 'GiB': 1024**3, 'TiB': 1024**4,
  'PiB': 1024**5, 'EiB': 1024**6, 'ZiB': 1024**7, 'YiB': 1024**8
}
SI_MULTIPLIERS = {
  'KB': 1000**1, 'MB': 1000**2, 'GB': 1000**3, 'TB': 1000**4,
  'PB': 1000**5, 'EB': 1000**6, 'ZB': 1000**7, 'YB': 1000**8
}
HUMAN_BYTESIZE_RE = re.compile(r'^\s*(\d+(?:\.\d+)?)\s*([a-zA-Z]*)\s*$')


def convert_to_bytes(size_str) -> int:
  match = HUMAN_BYTESIZE_RE.match(size_str)
  if not match: raise ValueError("Invalid size format")
  number, unit = match.groups()
  number = float(number)

  if unit in IE_MULTIPLIERS: multiplier = IE_MULTIPLIERS[unit]
  elif unit in SI_MULTIPLIERS: multiplier = SI_MULTIPLIERS[unit]
  elif unit == 'B' or unit == '': multiplier = 1
  else: raise ValueError("Unknown unit: {}".format(unit))

  return int(number * multiplier)
