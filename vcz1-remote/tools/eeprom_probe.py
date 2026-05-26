from pyftdi.spi import SpiController

spi = SpiController()
spi.configure('ftdi://ftdi:232h/1')
# CS0 = ADBUS3 (D3), SCK=D0, MOSI/SI=D1, MISO/SO=D2 ; SPI mode 0
eeprom = spi.get_port(cs=0, freq=1_000_000, mode=0)

status = eeprom.exchange([0x05], 1)          # RDSR
head   = eeprom.exchange([0x03, 0x00, 0x00], 16)  # READ from 0x0000, 16 bytes
print("status register (RDSR):", status.hex())
print("first 16 bytes @0x0000:", head.hex())
spi.terminate()
