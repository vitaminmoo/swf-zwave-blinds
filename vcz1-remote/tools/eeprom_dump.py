import sys
from pyftdi.spi import SpiController

SIZE = 32 * 1024  # CAV25256: 256 Kbit = 32 KiB

spi = SpiController()
spi.configure('ftdi://ftdi:232h/1')
eeprom = spi.get_port(cs=0, freq=1_000_000, mode=0)

data = bytes(eeprom.exchange([0x03, 0x00, 0x00], SIZE))  # READ from 0x0000
spi.terminate()

out = sys.argv[1]
with open(out, 'wb') as f:
    f.write(data)
print(f"wrote {len(data)} bytes to {out}")
