#pragma once

#include <CoreFoundation/CoreFoundation.h>
#include <stdint.h>
#include <sys/types.h>

#include "OnBlastVirtualAudioConstants.h"

#define OBTransportSharedMemoryMagic 0x4D424954U
#define OBTransportSharedMemoryVersion 2U
#define OBTransportSharedMemoryRingFrameCapacity 96000U

typedef struct {
    uint32_t magic;
    uint32_t version;
    uint32_t sampleRate;
    uint32_t bufferFrameSize;
    uint32_t channelCount;
    uint32_t ringFrameCapacity;
    uint32_t muted;
    uint32_t running;
    uint32_t sourceConnected;
    _Atomic uint64_t writeFrameCounter;
    float ringBuffer[OBTransportSharedMemoryRingFrameCapacity];
} OBTransportSharedMemory;

const char *OBTransportSharedMemoryPath(void);
size_t OBTransportSharedMemorySize(void);
int OBTransportOpenSharedMemory(int createIfNeeded, int *outFileDescriptor, OBTransportSharedMemory **outSharedMemory);
void OBTransportCloseSharedMemory(int fileDescriptor, OBTransportSharedMemory *sharedMemory);
void OBTransportInitialize(OBTransportSharedMemory *sharedMemory);
void OBTransportSetSampleRate(OBTransportSharedMemory *sharedMemory, uint32_t sampleRate);
void OBTransportSetBufferFrameSize(OBTransportSharedMemory *sharedMemory, uint32_t bufferFrameSize);
void OBTransportSetMuted(OBTransportSharedMemory *sharedMemory, uint32_t muted);
void OBTransportSetRunning(OBTransportSharedMemory *sharedMemory, uint32_t running);
void OBTransportSetSourceConnected(OBTransportSharedMemory *sharedMemory, uint32_t sourceConnected);
void OBTransportWriteMonoFloat(OBTransportSharedMemory *sharedMemory, const float *frames, uint32_t frameCount);
void OBTransportReadMonoFloat(OBTransportSharedMemory *sharedMemory, float *destination, uint32_t frameCount, uint64_t *ioReadFrameCounter);
