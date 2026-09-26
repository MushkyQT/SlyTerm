#ifndef CMULTITOUCH_H
#define CMULTITOUCH_H
#include <stdint.h>

// Private MultitouchSupport contact layout (reverse-engineered); kept in C so the memory layout
// matches what the framework writes.

typedef struct { float x, y; } MTPoint;
typedef struct { MTPoint position, velocity; } MTVector;

typedef struct {
    int32_t frame;
    double timestamp;
    int32_t identifier;
    int32_t state;        // 0 not tracking, 1 start in range, 2 hover, 3 make touch, 4 touching, 5 break touch, 6 linger, 7 out of range
    int32_t fingerID;
    int32_t handID;
    MTVector normalized;  // position in 0...1, origin bottom-left
    float zTotal;
    int32_t field9;
    float angle;
    float majorAxis;
    float minorAxis;
    MTVector absolute;    // millimetres
    int32_t field14;
    int32_t field15;
    float zDensity;
} MTTouch;

typedef int (*MTContactCallbackFunction)(void *device, MTTouch *touches, int numTouches, double timestamp, int frame);

#endif
