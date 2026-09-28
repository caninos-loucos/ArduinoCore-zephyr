#ifndef Pins_Arduino_h
#define Pins_Arduino_h

#include <stdint.h>

#define NUM_DIGITAL_PINS  20
#define NUM_ANALOG_INPUTS 0

#define PIN_SPI_SS   (10)
#define PIN_SPI_MOSI (11)
#define PIN_SPI_MISO (12)
#define PIN_SPI_SCK  (13)

#define SS PIN_SPI_SS
#define MOSI PIN_SPI_MOSI
#define MISO PIN_SPI_MISO
#define SCK PIN_SPI_SCK

#define PIN_WIRE_SDA (18)
#define PIN_WIRE_SCL (19)

#define SDA PIN_WIRE_SDA
#define SCL PIN_WIRE_SCL

#endif
